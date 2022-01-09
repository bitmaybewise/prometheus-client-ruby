# encoding: UTF-8

require 'base64'
require 'thread'
require 'net/http'
require 'uri'
require 'erb'
require 'set'

require 'prometheus/client'
require 'prometheus/client/formats/text'
require 'prometheus/client/label_set_validator'

module Prometheus
  # Client is a ruby implementation for a Prometheus compatible client.
  module Client
    # Push implements a simple way to transmit a given registry to a given
    # Pushgateway.
    class Push
      class HttpError < StandardError; end
      class HttpRedirectError < HttpError; end
      class HttpClientError < HttpError; end
      class HttpServerError < HttpError; end

      DEFAULT_GATEWAY = 'http://localhost:9091'.freeze
      PATH            = '/metrics/job/%s'.freeze
      SUPPORTED_SCHEMES = %w(http https).freeze

      attr_reader :job, :gateway, :path

      def initialize(job:, gateway: DEFAULT_GATEWAY, grouping_key: {}, **kwargs)
        raise ArgumentError, "job cannot be nil" if job.nil?
        raise ArgumentError, "job cannot be empty" if job.empty?
        @validator = LabelSetValidator.new(expected_labels: grouping_key.keys)
        @validator.validate_symbols!(grouping_key)

        @mutex = Mutex.new
        @job = job
        @gateway = gateway || DEFAULT_GATEWAY
        @grouping_key = grouping_key
        @path = build_path(job, grouping_key)
        @uri = parse("#{@gateway}#{@path}")

        @http = Net::HTTP.new(@uri.host, @uri.port)
        @http.use_ssl = (@uri.scheme == 'https')
        @http.open_timeout = kwargs[:open_timeout] if kwargs[:open_timeout]
        @http.read_timeout = kwargs[:read_timeout] if kwargs[:read_timeout]
      end

      def add(registry)
        synchronize do
          request(Net::HTTP::Post, registry)
        end
      end

      def replace(registry)
        synchronize do
          request(Net::HTTP::Put, registry)
        end
      end

      def delete
        synchronize do
          request(Net::HTTP::Delete)
        end
      end

      private

      def parse(url)
        uri = URI.parse(url)

        unless SUPPORTED_SCHEMES.include?(uri.scheme)
          raise ArgumentError, 'only HTTP gateway URLs are supported currently.'
        end

        uri
      rescue URI::InvalidURIError => e
        raise ArgumentError, "#{url} is not a valid URL: #{e}"
      end

      def build_path(job, grouping_key)
        path = format(PATH, ERB::Util::url_encode(job))

        grouping_key.each do |label, value|
          if value.include?('/')
            encoded_value = Base64.urlsafe_encode64(value)
            path += "/#{label}@base64/#{encoded_value}"
          # While it's valid for the urlsafe_encode64 function to return an
          # empty string when the input string is empty, it doesn't work for
          # our specific use case as we're putting the result into a URL path
          # segment. A double slash (`//`) can be normalised away by HTTP
          # libraries, proxies, and web servers.
          #
          # For empty strings, we use a single padding character (`=`) as the
          # value.
          #
          # See the pushgateway docs for more details:
          #
          # https://github.com/prometheus/pushgateway/blob/6393a901f56d4dda62cd0f6ab1f1f07c495b6354/README.md#url
          elsif value.empty?
            path += "/#{label}@base64/="
          else
            path += "/#{label}/#{ERB::Util::url_encode(value)}"
          end
        end

        path
      end

      def request(req_class, registry = nil)
        validate_no_label_clashes!(registry) if registry

        req = req_class.new(@uri)
        req.content_type = Formats::Text::CONTENT_TYPE
        req.basic_auth(@uri.user, @uri.password) if @uri.user
        req.body = Formats::Text.marshal(registry) if registry

        response = @http.request(req)
        validate_response!(response)

        response
      end

      def synchronize
        @mutex.synchronize { yield }
      end

      def validate_no_label_clashes!(registry)
        # There's nothing to check if we don't have a grouping key
        return if @grouping_key.empty?

        # We could be doing a lot of comparisons, so let's do them against a
        # set rather than an array
        grouping_key_labels = @grouping_key.keys.to_set

        registry.metrics.each do |metric|
          metric.labels.each do |label|
            if grouping_key_labels.include?(label)
              raise LabelSetValidator::InvalidLabelSetError,
                "label :#{label} from grouping key collides with label of the " \
                "same name from metric :#{metric.name} and would overwrite it"
            end
          end
        end
      end

      def validate_response!(response)
        status = Integer(response.code)
        if status >= 300
          message = "status: #{response.code}, message: #{response.message}, body: #{response.body}"
          if status <= 399
            raise HttpRedirectError, message
          elsif status <= 499
            raise HttpClientError, message
          else
            raise HttpServerError, message
          end
        end
      end
    end
  end
end
