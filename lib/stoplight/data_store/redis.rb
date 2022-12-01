# frozen_string_literal: true

require 'redlock'

module Stoplight
  module DataStore
    # @see Base
    class Redis < Base
      KEY_PREFIX = 'stoplight'
      KEY_SEPARATOR = ':'

      # @param redis [::Redis]
      def initialize(redis, redlock: Redlock::Client.new([redis]))
        @redis = redis
        @redlock = redlock
      end

      def names
        state_names = @redis.hkeys(states_key)

        pattern = key('failures', '*')
        prefix_regex = /^#{key('failures', '')}/
        failure_names = @redis.scan_each(match: pattern).to_a.map do |key|
          key.sub(prefix_regex, '')
        end

        (state_names + failure_names).uniq
      end

      def get_all(light)
        failures, state = @redis.multi do |transaction|
          query_failures(light, transaction: transaction)
          transaction.hget(states_key, light.name)
        end

        [
          normalize_failures(failures, light.error_notifier),
          normalize_state(state)
        ]
      end

      def get_failures(light)
        normalize_failures(query_failures(light), light.error_notifier)
      end

      def record_failure(light, failure)
        size, = @redis.multi do |transaction|
          transaction.lpush(failures_key(light), failure.to_json)
          transaction.ltrim(failures_key(light), 0, light.threshold - 1)
        end

        size
      end

      def clear_failures(light)
        failures, = @redis.multi do |transaction|
          query_failures(light, transaction: transaction)
          transaction.del(failures_key(light))
        end

        normalize_failures(failures, light.error_notifier)
      end

      def get_state(light)
        query_state(light) || State::UNLOCKED
      end

      def set_state(light, state)
        @redis.hset(states_key, light.name, state)
        state
      end

      def clear_state(light)
        state, = @redis.multi do |transaction|
          query_state(light, transaction: transaction)
          transaction.hdel(states_key, light.name)
        end

        normalize_state(state)
      end

      LOCK_TTL = 2_000 # milliseconds

      def with_notification_lock(light, from_color, to_color)
        @redlock.lock(notification_lock_key(light), LOCK_TTL) do
          if last_notification(light) != [from_color, to_color]
            set_last_notification(light, from_color, to_color)

            yield
          end
        end
      end

      private

      # @param light [Stoplight::Light]
      # @return [Array, nil]
      def last_notification(light)
        @redis.get(last_notification_key(light))&.split('->')
      end

      # @param light [Stoplight::Light]
      # @param from_color [String]
      # @param to_color [String]
      # @return [void]
      def set_last_notification(light, from_color, to_color)
        @redis.set(last_notification_key(light), [from_color, to_color].join('->'))
      end

      def query_failures(light, transaction: @redis)
        transaction.lrange(failures_key(light), 0, -1)
      end

      def normalize_failures(failures, error_notifier)
        failures.map do |json|
          Failure.from_json(json)
        rescue StandardError => e
          error_notifier.call(e)
          Failure.from_error(e)
        end
      end

      def query_state(light, transaction: @redis)
        transaction.hget(states_key, light.name)
      end

      def normalize_state(state)
        state || State::UNLOCKED
      end

      def failures_key(light)
        key('failures', light.name)
      end

      def notification_lock_key(light)
        key('notification_lock', light.name)
      end

      def last_notification_key(light)
        key('last_notification', light.name)
      end

      def states_key
        key('states')
      end

      def key(*pieces)
        ([KEY_PREFIX] + pieces).join(KEY_SEPARATOR)
      end
    end
  end
end
