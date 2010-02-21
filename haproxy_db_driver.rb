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

require 'rubygems'
require 'socket'
require 'dbi'
require 'ftools'
require 'yaml'
require 'logging'

# setup a logging instance
logger = Logging.logger(STDOUT)
logger.level = :info

# default configuration file path
DEFAULT_CONFIG_PATH = '/etc/haproxy_db_driver.rb'

# if we've been passed a configuration file on the command line, then
# use it instead of the default path
if ARGV && ARGV.size > 0

  CONFIG_PATH = ARGV[0]
else

  CONFIG_PATH = DEFAULT_CONFIG_PATH
end

# if the config file doesn't exist, exit
if !File.exists?(CONFIG_PATH)

  logger.warn "No configuration file found at #{CONFIG_PATH}"
  exit
end

# load in our configuration
configuration = YAML::load_file(CONFIG_PATH)

# configuration
BIND_ADDRESS = configuration["ip_address"]
BIND_PORT = configuration["port"]
NUM_PROCESSES = configuration["children"]
DB_ENGINE = configuration["db_engine"]
DB_NAME = configuration["db_name"]
DB_HOST = configuration["db_host"]
DB_USER = configuration["db_username"]
DB_PASSWORD = configuration["db_password"]
PID_FILE = configuration["pid_file_path"]

# create a socket and bind to port
acceptor = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
address = Socket.pack_sockaddr_in(BIND_PORT, BIND_ADDRESS)
acceptor.bind(address)

# start listening on the socket
acceptor.listen(10)

# remove the pid file, if it exists
if File.exists?(PID_FILE)

  begin

    File.delete(PID_FILE)
  rescue

    # the pid file isn't writable, warn and quit
    logger.warn("Could not delete pid file at #{PID_FILE}")
    exit
  end
end

# add our pid to the pid file and close the file
pid_file_handle = File.open(PID_FILE, 'a')

# fork the child processes
NUM_PROCESSES.times do |worker_id|

  # create a new child process, write the pid to our file
  pid = fork do

    # the child processes will exit when interrupted. note that their
    # pids will still be in the pid file, even if they exit early.
    trap('INT') do

      exit
    end

    loop do

      # block until a new connection is ready to be de-queued
      socket, addr = acceptor.accept

      # get the incoming message
      incoming_message = socket.gets

      # flag to indicate successful connection
      db_is_connected = false

      begin

        # connect to the db server
        cn = DBI.connect("dbi:#{DB_ENGINE}:#{DB_NAME}:#{DB_HOST}",
                         DB_USER, DB_PASSWORD)

        # make sure our connection is good
        db_is_connected = cn.connected?
      rescue

        message = "Uh-oh! #{DB_ENGINE} did not respond. :("
      ensure

        # close our data base connection
        if cn

          cn.disconnect
        end
      end

      # log the status of our connection
      logger.info  message

      # send our status
      if db_is_connected

        logger.info "db_is_connected"
        socket.write "HTTP/1.1 200 OK\n"
      else

        socket.write "HTTP/1.1 503 Service Unavailable\n"
      end

      # send the header
      socket.write "Date: #{Time.now}\r\n"
      socket.write "Server: Simple Ruby Server\r\n"
      socket.write "Expires: #{Time.now}\r\n"
      socket.write "Content-Type: text/html; charset=UTF-8\r\n"
      socket.write "\r\n"

      # send out message
      socket.write "#{message}\r\n"

      # close and flush our socket
      if socket
        socket.flush
        socket.close
      end
    end
  end

  # write out the pid of the child process
  pid_file_handle.puts(pid)
end

# close our pid file
pid_file_handle.close

# trap for interrupt
trap('INT') do

  # close our port
  acceptor.close

  # remove the pid file, if it exists
  if File.exists?(PID_FILE)

    begin

      File.delete(PID_FILE)
    rescue

      # the pid file isn't writable, warn and quit
      logger.warn("Could not delete pid file at #{PID_FILE}")
    end
  end

  # our work here is done
  exit
end

# wait for all child processes to exit
Process.waitall
