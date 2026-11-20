#!/usr/bin/env ruby
# Local, read-only server for the generated documentation archive.
require 'socket'
require 'uri'
require 'timeout'
root = File.expand_path(ARGV.fetch(0, __dir__))
port = Integer(ARGV.fetch(1, '8788'))
abort 'Invalid documentation directory or port' unless File.file?(File.join(root, 'index.html')) && (1024..65535).cover?(port)
server = TCPServer.new('127.0.0.1', port)
puts "Documentation: http://127.0.0.1:#{port}/VQMetrix/"
loop do
  client = server.accept
  Thread.new(client) do |socket|
    begin
      Timeout.timeout(10) do
        request = socket.gets(8192).to_s.split
        abort_request = request.length < 2 || !%w[GET HEAD].include?(request[0])
        raise ArgumentError, 'Unsupported request' if abort_request
        bytes = 0
        while (line = socket.gets(8192)) && line != "\r\n"
          bytes += line.bytesize
          raise ArgumentError if bytes > 16384
        end
        path = URI::DEFAULT_PARSER.unescape(request[1].split('?').first)
        path = path.sub(%r{\A/VQMetrix}, '')
        target = File.expand_path('.' + path, root)
        allowed = target == root || target.start_with?(root + File::SEPARATOR)
        target = File.join(target, 'index.html') if allowed && File.directory?(target)
        if allowed && File.file?(target)
          body = File.binread(target)
          type = {'.html'=>'text/html; charset=utf-8', '.css'=>'text/css', '.js'=>'application/javascript', '.json'=>'application/json', '.svg'=>'image/svg+xml', '.png'=>'image/png', '.woff2'=>'font/woff2', '.woff'=>'font/woff'}.fetch(File.extname(target), 'application/octet-stream')
          socket.write("HTTP/1.1 200 OK\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n")
          socket.write(body) unless request[0] == 'HEAD'
        else
          socket.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        end
      end
    rescue StandardError
      # Close malformed or disconnected local clients.
    ensure
      socket.close
    end
  end
end
