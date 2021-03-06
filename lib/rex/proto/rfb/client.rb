# -*- coding: binary -*-

##
#
# RFB protocol support
#
# by Joshua J. Drake <jduck>
#
# Based on:
# vnc_auth_none contributed by Matteo Cantoni <goony[at]nothink.org>
# vnc_auth_login contributed by carstein <carstein.sec[at]gmail.com>
#
# TODO: determine how to detect a view-only session.
##

module Rex
module Proto
module RFB

class Client

	def initialize(sock, opts = {})
		@sock = sock
		@opts = opts

		@banner = nil
		@majver = MajorVersion
		@minver = -1
		@auth_types = []
	end

	def read_error_message
		len = @sock.get_once(4)
		return 'Unknown error' if not len or len.length != 4

		len = len.unpack("N").first
		@sock.get_once(len)
	end

	def handshake
		@banner = @sock.get_once(12)
		if not @banner
			@error = "Unable to obtain banner from server"
			return false
		end

		# RFB Protocol Version 3.3 (1998-01)
		# RFB Protocol Version 3.7 (2003-08)
		# RFB Protocol Version 3.8 (2007-06)

		if @banner =~ /RFB ([0-9]{3})\.([0-9]{3})/
			maj = $1.to_i
			if maj != MajorVersion
				@error = "Invalid major version number: #{maj}"
				return false
			end
		else
			@error = "Invalid RFB banner: #{@banner}"
			return false
		end

		@minver = $2.to_i

		our_ver = "RFB %03d.%03d\n" % [MajorVersion, @minver]
		@sock.put(our_ver)

		true
	end

	def connect(password = nil)
		return false if not handshake
		return false if not authenticate(password)
		return false if not send_client_init
		true
	end

	def send_client_init
		if @opts[:exclusive]
			@sock.put("\x00") # do share.
		else
			@sock.put("\x01") # do share.
		end
	end

	def authenticate(password = nil)
		type = negotiate_authentication
		return false if not type

		# Authenticate.
		case type
		when AuthType::None
			# Nothing here.

		when AuthType::VNC
			return false if not negotiate_vnc_auth(password)

		end

		# Handle reading the security result message
		result = @sock.get_once(4)
		if not result
			@error = "Unable to read auth result"
			return false
		end

		result = result.unpack('N').first
		case result
		when 0
			return true

		when 1
			if @minver >= 8
				msg = read_error_message
				@error = "Authentication failed: #{msg}"
			else
				@error = "Authentication failed"
			end
		when 2
			@error = "Too many authentication attempts"
		else
			@error = "Unknown authentication result: #{result}"
		end

		false
	end

	def negotiate_authentication
		# Authentication type negotiation is protocol version specific.
		if @minver < 7
			buf = @sock.get_once(4)
			if not buf
				@error = "Unable to obtain requested authentication method"
				return nil
			end
			@auth_types = buf.unpack('N')
			if not @auth_types or @auth_types.first == 0
				msg = read_error_message
				@error = "No authentication types available: #{msg}"
				return nil
			end
		else
			buf = @sock.get_once(1)
			if not buf
				@error = "Unable to obtain supported authentication method count"
				return nil
			end

			# first byte is number of security types
			num_types = buf.unpack("C").first
			if (num_types == 0)
				msg = read_error_message
				@error = "No authentication types available: #{msg}"
				return nil
			end

			buf = @sock.get_once(num_types)
			if not buf or buf.length != num_types
				@error = "Unable to read authentication types"
				return nil
			end

			@auth_types = buf.unpack("C*")
		end

		if not @auth_types or @auth_types.length < 1
			@error = "No authentication types found"
			return nil
		end

		# Select the one we prefer
		selected = nil
		selected ||= AuthType::None if @opts[:allow_none] and @auth_types.include? AuthType::None
		selected ||= AuthType::VNC if @auth_types.include? AuthType::VNC

		if not selected
			@error = "No supported authentication method found."
			return nil
		end

		# For 3.7 and later, clients must state which security-type to use
		@sock.put([selected].pack('C')) if @minver >= 7

		selected
	end

	def negotiate_vnc_auth(password = nil)
		challenge = @sock.get_once(16)
		if not challenge or challenge.length != 16
			@error = "Unable to obtain VNC challenge"
			return false
		end

		response = Cipher.encrypt(challenge, password)
		@sock.put(response)

		true
	end

	attr_reader :error, :majver, :minver, :auth_types
	attr_reader :view_only
end

end
end
end
