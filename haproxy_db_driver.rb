#!/usr/bin/ruby
#
# A simple pre-forking server that tests to make sure the MySQL server
# is available.
#
# Based so heavily on the following article by Ryan Tomakyo that it's
# practically a verbatim copy.
#
#  http://tomayko.com/writings/unicorn-is-unix
#
# Pasted at http://gist.github.com/213990
#
class HaproxyDbDriver

  require 'rubygems'
  require 'socket'
  require 'dbi'
  require 'ftools'
  require 'yaml'
  require 'logging'

  # default configuration file path
  DEFAULT_CONFIG_PATH = '/etc/haproxy_db_driver.rb'

  # array of child processes
  CHILDREN = Array.new

  # log level for console output
  attr_accessor :log_level

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
  attr_accessor :pid_file_path

  def initialize(config_path = DEFAULT_CONFIG_PATH)

    # setup a logging instance
    @logger = Logging.logger(STDOUT)
    @logger.level = :info

    # make sure our configuration file exists
    if !File.exists?(config_path)

      @logger.warn "No configuration file found at #{CONFIG_PATH}"
      raise "No configuration file found at #{config_path}"
    end

    # load in our configuration
    configuration = YAML::load_file(config_path)

    # set our variables
    @ip_address = configuration["ip_address"]
    @port = configuration["port"]
    @children = configuration["children"]
    @db_engine = configuration["db_engine"]
    @db_name = configuration["db_name"]
    @db_host = configuration["db_host"]
    @db_username = configuration["db_username"]
    @db_password = configuration["db_password"]
    @pid_file_path = configuration["pid_file_path"]
  end

  def remove_pid

    # remove the pid file, if it exists
    if File.exists?(@pid_file_path)

      begin

        File.delete(@pid_file_path)
      rescue

        # the pid file isn't writable, warn and quit
        @logger.warn("Could not delete pid file at #{@pid_file_path}")
        exit
      end
    end
  end

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

        # get the incoming message
        incoming_message = client.gets

        # flag to indicate successful connection
        db_is_connected = false

        begin

          # connect to the db server
          dbi_handle = DBI.connect("dbi:#{@db_engine}:#{@db_name}:#{@db_host}",
                                   @db_username, @db_password)

          # make sure our connection is good
          db_is_connected = dbi_handle.connected?

          # indicate that the database is running
          message = "#{db_host} is working hard. :)"
        rescue

          # indicate that the database is down or busy
          message = "Uh-oh! #{@db_host} did not respond. :("
        ensure

          # close our data base connection
          if dbi_handle

            dbi_handle.disconnect
          end
        end

        # log the status of our connection
        @logger.info(message)

        # send the response code, we return a 503 if the database
        # didn't respond
        if db_is_connected

          client.write "HTTP/1.1 200 OK\n"
        else

          client.write "HTTP/1.1 503 Service Unavailable\n"
        end

        # send the rest of the header
        client.write "Date: #{Time.now}\r\n"
        client.write "Server: Simple Ruby Server\r\n"
        client.write "Expires: #{Time.now}\r\n"
        client.write "Content-Type: text/html; charset=UTF-8\r\n"
        client.write "\r\n"

        # send out message
        client.write "#{message}\r\n"

        # close and flush our socket
        client.flush
        client.close
      end
    end

    # return the pid of this child process
    return(pid)
  end

  def start_server

    @logger.info("Starting the Haproxy DB Driver process...")

    # create a socket and bind to port
    socket = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
    socket_address = Socket.pack_sockaddr_in(@port, @ip_address)
    socket.bind(socket_address)

    # start listening on the socket
    socket.listen(10)

    # remove any old pid files
    remove_pid

    # add our pid to the pid file and close the file
    pid_file_handle = File.open(@pid_file_path, 'a')

    # write out our pid
    pid_file_handle.puts(Process.pid)

    @children.times do

      # start a new child process
      child_pid = start_child(socket)

      # add the pid to our array of children
      CHILDREN << child_pid

      # write the child's pid to our pid file
      pid_file_handle.puts(child_pid)
    end

    # close the pid file
    pid_file_handle.close

    # trap for interrupts and exit
    ['INT', 'EXIT', 'TERM'].each do |signal|

      # in both cases, shut down the server
      trap(signal) do

        @logger.info("Shutting down Haproxy DB Driver...")

        # loop through our children and kill each one
        CHILDREN.each do |child_pid|

          Process.kill('TERM', child_pid)
        end

        # close our port
        socket.close

        # remove our pid file
        remove_pid
      end
    end
  end
end

require 'rubygems'
require 'logging'

# setup a logging instance
logger = Logging.logger(STDOUT)
logger.level = :info

# start a new haproxy db driver
haproxy_db_driver = HaproxyDbDriver.new(ARGV[0])
haproxy_db_driver.start_server

# wait for all child processes to exit
Process.waitall
