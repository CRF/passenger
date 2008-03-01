require 'socket'
require 'base64'
require 'passenger/message_channel'
require 'passenger/cgi_fixed'
require 'passenger/utils'

module Passenger

class RequestHandler
	# Signal which will cause the Rails application to exit immediately.
	HARD_TERMINATION_SIGNAL = "SIGTERM"
	# Signal which will cause the Rails application to exit as soon as it's done processing a request.
	SOFT_TERMINATION_SIGNAL = "SIGUSR1"
	BACKLOG_SIZE = 50
	
	# String constants which exist to relieve Ruby's garbage collector.
	IGNORE = 'IGNORE' # :nodoc:
	DEFAULT = 'DEFAULT' # :nodoc:
	CONTENT_LENGTH = 'CONTENT_LENGTH' # :nodoc:
	HTTP_CONTENT_LENGTH = 'HTTP_CONTENT_LENGTH' # :nodoc:
	
	attr_reader :socket_name

	def initialize(owner_pipe)
		if ENV['PASSENGER_NO_ABSTRACT_NAMESPACE_SOCKETS'].blank?
			@using_abstract_namespace = create_unix_socket_on_abstract_namespace
		else
			@using_abstract_namespace = false
		end
		if !@using_abstract_namespace
			create_unix_socket_on_filesystem
		end
		@owner_pipe = owner_pipe
		@previous_signal_handlers = {}
	end
	
	def cleanup
		@socket.close rescue nil
		@owner_pipe.close rescue nil
		if !using_abstract_namespace?
			File.unlink(@socket_name) rescue nil
		end
	end
	
	def using_abstract_namespace?
		return @using_abstract_namespace
	end
	
	def main_loop
		reset_signal_handlers
		begin
			done = false
			while !done
				client = accept_connection
				if client.nil?
					break
				end
				trap SOFT_TERMINATION_SIGNAL do
					done = true
				end
				process_request(client)
				trap SOFT_TERMINATION_SIGNAL, DEFAULT
			end
		rescue EOFError
			# Exit main loop.
		rescue Interrupt
			# Exit main loop.
		rescue SignalException => signal
			if signal.message != HARD_TERMINATION_SIGNAL &&
			   signal.message != SOFT_TERMINATION_SIGNAL
				raise
			end
		ensure
			revert_signal_handlers
		end
	end

private
	def create_unix_socket_on_abstract_namespace
		while true
			begin
				# I have no idea why, but using base64-encoded IDs
				# don't pass the unit tests. I couldn't find the cause
				# of the problem. The system supports base64-encoded
				# names for abstract namespace unix sockets just fine.
				@socket_name = generate_random_id(:hex)
				@socket_name = @socket_name.slice(0, NativeSupport::UNIX_PATH_MAX - 2)
				fd = NativeSupport.create_unix_socket("\x00#{socket_name}", BACKLOG_SIZE)
				@socket = IO.new(fd)
				@socket.instance_eval do
					def accept
						fd = NativeSupport.accept(fileno)
						return IO.new(fd)
					end
				end
				return true
			rescue Errno::EADDRINUSE
				# Do nothing, try again with another name.
			rescue Errno::ENOENT
				# Abstract namespace sockets not supported on this system.
				return false
			end
		end
	end
	
	def create_unix_socket_on_filesystem
		done = false
		while !done
			begin
				@socket_name = "/tmp/passenger.#{generate_random_id(:base64)}"
				@socket_name = @socket_name.slice(0, NativeSupport::UNIX_PATH_MAX - 1)
				@socket = UNIXServer.new(@socket_name)
				File.chmod(0600, @socket_name)
				done = true
			rescue Errno::EADDRINUSE
				# Do nothing, try again with another name.
			end
		end
	end

	def reset_signal_handlers
		Signal.list.each_key do |signal|
			begin
				prev_handler = trap(signal, DEFAULT)
				if prev_handler != DEFAULT
					@previous_signal_handlers[signal] = prev_handler
				end
			rescue ArgumentError
				# Signal cannot be trapped; ignore it.
			end
		end
		prev_handler = trap('HUP', IGNORE)
	end
	
	def revert_signal_handlers
		@previous_signal_handlers.each_pair do |signal, handler|
			trap(signal, handler)
		end
	end
	
	def accept_connection
		ios = select([@socket, @owner_pipe])[0]
		if ios.include?(@socket)
			return @socket.accept
		else
			# The other end of the pipe has been closed.
			# So we know all owning processes have quit.
			return nil
		end
	end
	
	class ResponseSender
		def initialize(io)
			@io = io
		end
		
		def write(block)
			@io.write(block)
		end
	end
	
	def process_request(socket)
		channel = MessageChannel.new(socket)
		headers_data = channel.read_scalar
		if headers_data.nil?
			socket.close
			return
		end
		
		headers = Hash[*headers_data.split("\0")]
		headers[CONTENT_LENGTH] = headers[HTTP_CONTENT_LENGTH]
		
		# TODO:
		# Uploaded files are apparently put in /tmp, but not as temp files.
		# That should be fixed.
		
		cgi = CGIFixed.new(headers, socket, ResponseSender.new(socket))
		::Dispatcher.dispatch(cgi, ::ActionController::CgiRequest::DEFAULT_SESSION_OPTIONS,
			cgi.stdoutput)
		socket.close
	end
	
	# Generate a long, cryptographically secure random ID string, which
	# is also a valid filename.
	def generate_random_id(method)
		case method
		when :base64
			data = Base64.encode64(File.read("/dev/urandom", 64))
			data.gsub!("\n", '')
			data.gsub!("+", '')
			data.gsub!("/", '')
			data.gsub!(/==$/, '')
		when :hex
			data = File.read("/dev/urandom", 64).unpack('H*')[0]
		end
		return data
	end
end

end # module Passenger