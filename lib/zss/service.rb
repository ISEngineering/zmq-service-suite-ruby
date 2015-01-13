require 'em-zeromq'
require_relative '../zss'
require_relative 'router'
require_relative 'message/smi'

module ZSS
  class Service

    include LoggerFacade::Loggable

    attr_reader :sid, :heartbeat, :backend, :identity

    def initialize(sid, config = {})

      fail Error[500] if sid.blank?

      @sid = sid.to_s.upcase
      @heartbeat = config.try(:heartbeat) || 1000
      @backend   = config.try(:backend) || Configuration.default.backend
      @router = ZSS::Router.new
      @identity = "#{sid}##{SecureRandom.uuid}"
    end

    def run
      Thread.abort_on_exception = true

      context = EM::ZeroMQ::Context.new(1)
      fail RuntimeError, 'failed to create create_context' unless context


      log.info("Starting SID: '#{sid}' ID: '#{identity}' Env: '#{ZSS::Environment.env}' Broker: '#{backend}'",
        metadata({
          broker: backend,
          env: ZSS::Environment.env
        }))

      EM.run do
        # handle interrupts
        Signal.trap("INT") { stop }
        Signal.trap("TERM") { stop }

        connect_socket context

        start_heartbeat_worker

        # send up message
        send Message::SMI.up(sid)
      end
    end

    def add_route(context, route, handler = nil)
      router.add(context, route, handler)
    end

    def stop
      timer.cancel if timer

      EM.add_timer do

        log.info("Stoping SID: '#{sid}' ID: '#{identity}'", metadata)

        send Message::SMI.down(sid)
        socket.disconnect backend
        EM::stop
      end
    end

    private

    attr_accessor :socket, :router, :timer

    def connect_socket(context)

      @socket = context.socket ZMQ::DEALER
      fail RuntimeError, 'failed to create socket' unless socket

      socket.identity = identity
      socket.setsockopt(ZMQ::LINGER, 0)
      socket.on(:message, &method(:handle_frames))

      socket.connect(backend)
    end

    def start_heartbeat_worker
      @timer = EventMachine::PeriodicTimer.new(heartbeat / 1000) do
        send Message::SMI.heartbeat(sid)
      end
    end

    def handle_frames(*frames)
      # we need to close frame to avoid memory leaks
      frames = frames.map do |frame|
        out_frame = frame.copy_out_string
        frame.close
        out_frame
      end

      handle Message.parse(frames)
    end

    def handle(message)
      if message.req?
        handle_request(message)
      else
        context = request_metadata(message)
        log.trace("SMI response received: \n #{message}", context) if log.is_debug
      end
    rescue ZSS::Error => error
      log.error("ZSS::Error raised while processing request: #{error}", metadata({ error: error }))
      reply_error error, message
    rescue => e
      log.error("Unexpected error occurred while processing request: #{e}", metadata({ exception: e }))
      reply_error Error[500], message
    end

    def handle_request(message)
      start_time = Time.now.utc
      log.info("Handle request for #{message.address}", request_metadata(message))
      log.trace("Request message:\n #{message}") if log.is_debug

      if message.address.sid != sid
        error = Error[404]
        error.developer_message = "Invalid SID: #{message.address.sid}!"
        fail error
      end

      # the router returns an handler that receives payload and headers
      handler = router.get(message.address.verb)
      message.payload = handler.call(message.payload, message.headers)
      message.headers["zss-response-time"] = ((Time.now.utc - start_time) * 1_000).to_i
      reply message
    end

    def reply_error(error, message)
      message.status = error.code
      message.payload = {
        errorCode: error.code,
        userMessage: error.user_message,
        developerMessage: error.developer_message
      }
      message.type = Message::Type::REP

      log.info("Reply with status: #{message.status}", request_metadata(message))

      send message
    end

    def reply(message)
      message.status = 200
      message.type = Message::Type::REP

      log.info("Reply with status: #{message.status}", metadata)
      log.trace("Reply with message:\n #{message}") if log.is_debug

      send message
    end

    def send(msg)
      log.trace("sending: \n #{msg}") if log.is_debug

      frames = msg.to_frames
      #remove identity frame on request
      frames.shift if msg.req?
      success = socket.send_msg(*frames)

      log.error("An Error ocurred while sending message", request_metadata(message)) unless success
    end

    def metadata(metadata = {})
      metadata ||= {}
      metadata[:sid] = sid
      metadata[:identity] = identity
      metadata[:pid] = Process.pid
      metadata
    end

    def request_metadata(message, metadata = {})
      metadata = metadata(metadata)

      metadata[:request] = message.to_log
      metadata
    end
  end
end
