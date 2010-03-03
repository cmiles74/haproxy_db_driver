#!/usr/bin/ruby
#
# Provides a pre-forking server that can be used as a driver for
# HAProxy. The server will respond with either a HTTP 200 header if
# the database is accepting connections and a http 503 header if it is
# not.

class HaproxyDbDriver
 
  require 'rubygems'
  require 'socket'
  require 'dbi'
  require 'yaml'
  require 'logging'
 

  # default configuration file path
  #DEFAULT_CONFIG_PATH = '/etc/haproxy_db_driver.rb'
  DEFAULT_CONFIG_PATH = '/usr/local/haproxy/health_checks/hadb_config.yml'
  LOG_FILE = '/usr/local/haproxy/health_checks/hadb.log'

  DEAD_LIMIT = 10
  
  # array of child processes
  CHILDREN = Array.new
 
  # log level for console output
  attr_accessor :log_level

=begin
  # ip address on which we'll listen
  attr_accessor :ip_address
 
  # the port on which we'll listen
  attr_accessor :port
 
  # the number of children process we'll spawn
  attr_accessor :children
 
  # the type of database we'll be checking
  attr_accessor :db_engine
 
  # the host that is running the database
  attr_accessor :db_host
 
  # the name of the database to which we will connect
  attr_accessor :db_name
 
  # the username to use when connecting to the database
  attr_accessor :db_username
 
  # the password to use when connecting to the database
  attr_accessor :db_password
 
  # the path to our pid file
  attr_accessor :pid_file
=end
 
  # Initializes the HaproxyDbDriver. If the path to a configuration
  # file is given, that file will be used when initializing the
  # instance. If no path is provided, we'll look in
  # /etc/haproxy_db_driver.yaml.
  #
  # The configuration file should be a YAML file that contains the
  # following keys...
  #
  # - log_level: console logger level
  # - ip_address: the IP address to which the server will bind
  # - port: the port ot which the server will bind
  # - children: the number of children process to fork
  # - db_engine: the type of database (DBI) to test
  # - db_name: the name of the database to test
  # - db_host: the server running the database to test
  # - db_username: the username to use when connecting to the database
  # - db_password: the password to use when connecting to the database
  # - pid_file: the path to the location to write the pids
  #
  # config_path:: path to the configuration file
  def initialize(args)



    config_path = args[0] || DEFAULT_CONFIG_PATH

    # setup a logging instance
    # may not need to do this here it gives warning already initialized constant MAX_LEVEL_LENGTH
    # as init script calls it already.
    # Logging.init :debug, :info, :warn, :error, :fatal
    layout = Logging::Layouts::Pattern.new :pattern => "[%d][%l][%c] %m\n"
    @logger = Logging.logger[self]
    @logger.add_appenders(
      Logging.appenders.file(LOG_FILE, :layout => layout)
      #Logging.appenders.stdout
    )
    @logger.level = :debug

    # make sure our configuration file exists
    if !File.exist?(config_path)
 
      @logger.warn "No configuration file found at #{config_path}"
      raise "No configuration file found at #{config_path}"
    end
 
    # load in our configuration
    @conf = YAML::load_file(config_path)

    # keys are strings not symbols (could do this in rails with HashWithIndifferentAccess
    # with header at top of YAML: --- !map:HashWithIndifferentAccess
    @server = @conf['server']
  end
 
  # Removes the pid file from the file system.
  def remove_pid
 
    # remove the pid file, if it exists
    if File.exist?(@server['pid_file'])
 
      begin
 
        File.delete(@server['pid_file'])
      rescue
 
        # the pid file isn't writable, warn and quit
        @logger.warn("Could not delete pid file at #{@server['pid_file']}")
        exit
      end
    end
  end

  # Starts a child process on the provided socket.
  #
  # socket:: The socket that the child process will use
  def start_child(socket)

    pid = fork do
 
      # the child processes will exit when interrupted. note that their
      # pids will still be in the pid file, even if they exit early.
      ['INT', 'EXIT', 'TERM'].each do |signal|
 
        # in both cases, shut down the child
        trap(signal) do
 
          exit
        end
      end

      loop do
 
        # block until a new connection is ready to be de-queued
        client, client_socket_address =socket.accept
 
        # get the requested check from incoming haproxy message
        incoming_message = client.gets
        db_check = incoming_message.to_s.split[1]
        db = @conf[db_check]

        # try to connect to specified db
        db_is_connected = false
        begin
          # connect to the db server
          case db['engine']
          when 'ODBC'
            dsn = "DBI:#{db['engine']}:#{db['name']}"
          else
            dsn = "DBI:#{db['engine']}:database=#{db['name']};host=#{db['host']};port=#{db['port']}"
          end
          dbi_handle = DBI.connect(dsn, db['username'], db['password'])
 
          # make sure our connection is good
          db_is_connected = dbi_handle.connected?
        rescue 
          db_is_connected = false
            
        ensure
 
          # close our data base connection
          if dbi_handle
            dbi_handle.disconnect
          end
        end
 
        # get db status from file
        status_file = "#{db_check}.status"
        db_status, down_count = read_status(status_file)

        # update file and close so next child gets updated status asap
        # ie don't wait for failover/stonith to complete before updating as this
        # will result possibly in several children trying to do failover

        if db_status == 'DEAD'
          # no need to update status file and only log in debug
          status_header = "HTTP/1.1 503 Service Unavailable"
          @logger.debug "#{db_check}: DEAD/#{db_is_connected ? 'UP':'DOWN'}"

        elsif !db_is_connected
          # always update status 
          status_header = "HTTP/1.1 503 Service Unavailable"
          down_count += 1
          if down_count >= DEAD_LIMIT 
            update_status status_file, 'DEAD', down_count
            @logger.error "#{db_check}: DEAD #{down_count}"

            system db['stonith_cmd'] if db['stonith_cmd']
            system db['failover_cmd'] if db['failover_cmd']
            
          else
            @logger.error "#{db_check}: DOWN #{down_count}"
            update_status status_file, 'DOWN', down_count
          end


        else
          # only update status if coming back up
          status_header = "HTTP/1.1 200 OK"

          if down_count > 0

            down_count = 0
            @logger.info "#{db_check} is back up. :)"
            update_status status_file, 'UP', down_count
          else
            @logger.debug "#{db_check}: is working hard. :)"
          end


        end

        # send response
        reply = "#{status_header}\n
          Date: #{Time.now}\r\n
          Server: Simple Ruby Server\r\n
          Expires: #{Time.now}\r\n
          Content-Type: text/html; charset=UTF-8\r\n
          \r\n"
 
        client.write reply
        client.flush
        client.close

      end
    end
 
    # return the pid of this child process
    return(pid)
  end

  def read_status(file_name)
    status = 'UP'
    down_count = 0
    if File.exist? file_name
      File.open(file_name) do |f|
        status = f.gets.to_s.chomp 
        down_count = f.gets.to_s.chomp.to_i
      end
    else
      update_status file_name, status, down_count
    end
    return status, down_count
  end

  def update_status(file_name, status, down_count)
    ts = Time.now
   # begin
      File.open(file_name, 'w') do |f|
        f.puts status
        f.puts down_count
        f.puts ts
      end
    @logger.info "#{file_name} update: #{status} #{down_count} #{ts}"


   # rescue

   # end
  end

  # Stops the children processes by sending each of them the
  # termination signal.
  def stop_children
 
    # loop through our children and kill each one
    CHILDREN.each do |child_pid|

      begin
        Process.kill('TERM', child_pid)
        @logger.info "killing child pid: #{child_pid}"
      rescue => e
        @logger.info "error killing child pid ##{child_pid}: #{e.message}"
      end
    end
  end
 
  # Starts a new server process and forks off our child
  # processes. This method will never return, it waits for all of the
  # children process to complete before exiting. This is a good thing,
  # the process that invokes this method will listen for termination
  # signals and will ensure that the child processes quit.
  def start_server
 
    @server_killed = false
    @logger.info("Starting the Haproxy DB Driver process...")



#FIXME needs to detect stale pids and whether server is actually already running
# by checking procs against pid. 

=begin
# doesn't work because this script is same name
#    @server_running = system("ps aux | grep #{__FILE__} | grep -v grep > /dev/null")
@server_running = false
    if File.exist? @server['pid_file']
      if @server_running
        @logger.info "Server already running"
        return
      else
        @logger.info "Removing stale pid file"
        remove_pid
      end
    else
      if @server_running
        @logger.error "Server already started, but has no pid file"
        return
      else
        # start server normally
      end
    end
=end
remove_pid

 
    # create a socket and bind to port
    socket = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
    
    # allow reuse of socket so we don't get Errno::EADDRINUSE and have to wait for
    # tcp socket to timeout. allows fast restart
    socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)

    socket_address = Socket.pack_sockaddr_in(@server['port'], @server['ip_address'])
    socket.bind(socket_address)
 
    # start listening on the socket
    socket.listen(10)
 
    # add our pid to the pid file and close the file
    pid_file_handle = File.open(@server['pid_file'], 'a')
 
    # write out our pid
    pid_file_handle.puts(Process.pid)
 
    @server['children'].times do
 
      # start a new child process
      child_pid = start_child(socket)
 
      # add the pid to our array of children
      CHILDREN << child_pid
 
      # write the child's pid to our pid file
      pid_file_handle.puts(child_pid)
    end
 
    # close the pid file
    pid_file_handle.close
 
    # trap for interrupts and exit - on debian anyway, EXIT is executed
    # regardless when shell exits so we were killing twice with TERM. Added
    # server_killed to still allow portability to non-debian system while preventing potential issues
    # with killing server multiple times.
    ['INT', 'EXIT', 'TERM'].each do |signal|
 
      # in both cases, shut down the server
      trap(signal) do
        unless @server_killed 
          @logger.info("Shutting down Haproxy DB Driver...")
 
          # stops the children processes
          stop_children
 
          # close our port
          socket.close
 
# remove our pid file - let init file do this
#remove_pid

          @server_killed = true
        end
      end
    end
 
    Process.wait
  end

end
 
# setup a logging instance
#logger = Logging.logger(STDOUT)
logger = Logging.logger(HaproxyDbDriver::LOG_FILE)
logger.level = :info
 
# start the server in a new process
pid = fork do

  # start a new haproxy db driver
  haproxy_db_driver = HaproxyDbDriver.new(ARGV)
  haproxy_db_driver.start_server

end

# detach the process so it can run in the background and exit the script
Process.detach(pid)

# just give drivers a second to fire up and make initial contact so haproxy
# doesn't start with primary marked down
sleep 2
