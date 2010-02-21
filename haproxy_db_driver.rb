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
require 'logging'

# default configuration file path
DEFAULT_CONFIG_PATH = '/etc/haproxy_db_driver.rb'

# configuration
BIND_ADDRESS = '127.0.0.1'
BIND_PORT = 'port'
NUM_PROCESSES = 5

DB_ENGINE = 'Pg'
DB_NAME = 'name'
DB_HOST = 'host'
DB_USER = 'user'
DB_PASSWORD = 'pwd'
PID_FILE = 'pgsql_check.pid'

DEAD_LIMIT = 5
dead_count = 0

TRIGGER_CMD = "ssh #{DB_HOST} \"su -c 'touch /tmp/pgsql.trigger' postgres\""

# setup a logging instance
logger = Logging.logger(STDOUT)
logger.level = :info

# create a socket and bind to port
acceptor = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
address = Socket.pack_sockaddr_in(BIND_PORT, BIND_ADDRESS)
acceptor.bind(address)

# start listening on the socket
acceptor.listen(10)

# trap for a process exit and stop listening
trap('EXIT') {

  acceptor.close
}

# fork the child processes
pid_file =  File.open(PID_FILE, 'a')

NUM_PROCESSES.times do |worker_id|

  fork do
    pid_file.puts Process.pid
    pid_file.close if worker_id = NUM_PROCESSES

    # trap for process break and exit
    trap('INT') { exit }

    # puts "child #$$ accepting on shared socket (localhost:9999)"

    loop {

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

        server_version = cn.server_version

        message = "#{DB_ENGINE} (version #{server_version}) is A-Okay!\n\n"
        db_is_connected = cn.connected?
      rescue

        message = "Uh-oh! #{DB_ENGINE} did not respond. :(\n\n"
      ensure

        cn.disconnect if cn
      end

      logger.info  message

      # send our status
      if db_is_connected
        logger.info "db_is_connected"
        socket.write "HTTP/1.1 200 OK\n"
      else
        logger.info "dead_count #{dead_count}"
        dead_count += 1
        socket.write "HTTP/1.1 503 Service Unavailable\n"
      end

      # send the header
      socket.write "Date: #{Time.now}\r\n"
      socket.write "Server: Simple Ruby Server\r\n"
      socket.write "Expires: #{Time.now}\r\n"
      socket.write "Content-Type: text/html; charset=UTF-8\r\n"
      socket.write "\r\n"

      # send out message
      socket.write message

      if socket
        socket.flush
        socket.close
      end

      if dead_count >= DEAD_LIMIT
        logger.info "DEAD!!"
        system TRIGGER_CMD 
      end
    }
  end
end

# trap interrupt and exit
trap('INT') {

  exit
}

# wait for all child processes to exit
Process.waitall

