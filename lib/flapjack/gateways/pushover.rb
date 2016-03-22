#!/usr/bin/env ruby

require 'em-synchrony'
require 'em-synchrony/em-http'
require 'active_support/inflector'

require 'flapjack/redis_pool'

require 'flapjack/data/alert'
require 'flapjack/utility'

module Flapjack
  module Gateways
    class Pushover

      include Flapjack::Utility

      def initialize(opts = {})
        @config = opts[:config]
        @logger = opts[:logger]
        @redis_config = opts[:redis_config] || {}
        @redis = Flapjack::RedisPool.new(:config => @redis_config, :size => 1, :logger => @logger)

        @logger.info("starting")
        @logger.debug("New Pushover gateway pikelet with the following options: #{@config.inspect}")

        @sent = 0
      end

      def stop
        @logger.info("stopping")
        @should_quit = true

        redis_uri = @redis_config[:path] ||
          "redis://#{@redis_config[:host] || '127.0.0.1'}:#{@redis_config[:port] || '6379'}/#{@redis_config[:db] || '0'}"
        shutdown_redis = EM::Hiredis.connect(redis_uri)
        shutdown_redis.rpush(@config['queue'], Flapjack.dump_json('notification_type' => 'shutdown'))
      end

      def start
        queue = @config['queue']

        until @should_quit
          begin
            @logger.debug("Pushover gateway is going into blpop mode on #{queue}")
            alert = Flapjack::Data::Alert.next(queue, :redis => @redis, :logger => @logger)
            deliver(alert) unless alert.nil?
          rescue => e
            @logger.error "Error generating or dispatching Pushover message: #{e.class}: #{e.message}\n" +
              e.backtrace.join("\n")
          end
        end
      end

      def deliver(alert)
        app_key = @config["app_key"]
        usr_key = @config["usr_key"]
        endpoint = @config["endpoint"]
        emergency_expire = @config["emergency_expire"]
        emergency_retry = @config["emergency_retry"]

        channel         = "##{alert.address}"
        channel         = '#general' if (channel.size == 1)
        notification_id = alert.notification_id
        message_type    = alert.rollup ? '-1' : '1'

        if alert.state == "ok" and alert.notification_type == "recovery"
          message_color = "#00ff00"
          message_priority = -1
        elsif alert.state == "warning"
          message_color = "#ffff00"
          message_priority = 1
        elsif alert.state == "critical"
          message_color = "#ff0000"
          message_priority = 1
        elsif alert.notification_type == "acknowledgement"
          message_color = "#0000ff"
          message_priority = -1
        else
          message_color = "#00ff00"
          message_priority = -1
        end

        @logger.info "Notification type is #{alert.notification_type}, state is #{alert.state}."
        @logger.info "Message color is #{message_color} with priority #{message_priority}"

        @alert  = alert
        bnd     = binding

        errors = []

        [
         [endpoint, "Pushover endpoint is missing"],
         [app_key, "Pushover app_key is missing"],
         [usr_key, "Pushover usr_key is missing"],
        ].each do |val_err|

          next unless val_err.first.nil? || (val_err.first.respond_to?(:empty?) && val_err.first.empty?)
          errors << val_err.last
        end

        unless errors.empty?
          errors.each {|err| @logger.error err }
          return
        end

        if alert.notification_type != "acknowledgement"
          alert_message = "#{alert.type_sentence_case}: '#{alert.check}' on #{alert.entity} is #{alert.state_title_case} at #{Time.at(@alert.time).strftime('%-d %b %H:%M')}."
        else
          alert_message = "#{alert.type_sentence_case}: '#{alert.check}' on #{alert.entity}"
        end

        pushover_message = {
          "token"     => app_key,
          "user"      => usr_key,
          "html"      => 1,
          "title"     => "#{alert.entity}",
          "message"   => alert_message,
          "priority"  => message_priority,
          "expire"    => emergency_expire,
          "retry"     => emergency_retry
          }

        @logger.debug "payload: #{pushover_message}"

        http = EM::HttpRequest.new("#{endpoint}").post :body => pushover_message

        status = (http.nil? || http.response_header.nil?) ? nil : http.response_header.status
        if (status >= 200) && (status <= 206)
          @sent += 1
          alert.record_send_success!
          @logger.debug "Sent message via Pushover - response status is #{status}, #{http.response}."
        else
          @logger.error "Failed to send message via Pushover - response status is #{status}, #{http.response}."
        end
      rescue => e
        @logger.error "Error generating or delivering Pushover messsage: #{e.message}"
        @logger.error e.backtrace.join("\n")
        raise
      end

    end
  end
end
