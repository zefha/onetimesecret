

module Onetime
  module Logic
    class Base
      unless defined?(Stella::Logic::Base::MOBILE_REGEX)
        MOBILE_REGEX = /^\+?\d{9,16}$/
        EMAIL_REGEX = %r{^(?:[_a-z0-9-]+)(\.[_a-z0-9-]+)*@([a-z0-9-]+)(\.[a-zA-Z0-9\-\.]+)*(\.[a-z]{2,4})$}i
      end
      attr_reader :sess, :cust, :params, :processed_params
      def initialize(sess, cust, params=nil)
        @sess, @cust, @params = sess, cust, params
        @processed_params ||= {}
        process_params if respond_to?(:process_params) && @params
        process_generic_params if @params
      end
      protected
      
      # can raise OT::UserLimitError or OT::HostLimitError
      def check_rate_limits!(event)
        sess.event_incr! event
      end

      # Generic params that can appear anywhere are processed here.
      # This is called in initialize AFTER process_params so that 
      # values set here don't overwrite values that already exist.
      def process_generic_params
        # remember to set with ||= 
      end
    end
    
    class CreateSecret < OT::Logic::Base
      attr_reader :passphrase, :secret_value, :kind
      attr_reader :metadata, :secret
      def process_params
        if ['share', 'generate'].member?(params[:kind].to_s)
          @kind = params[:kind].to_s.to_sym 
        end
        @secret_value = params[:secret].to_s
        @passphrase = params[:passphrase].to_s
      end
      def raise_concerns
        raise OT::Problem, "No secret value" if kind == :share && secret_value.empty?
        raise OT::Problem, "Unknown type of secret" if kind.nil?
      end
      def process
        @metadata, @secret = Onetime::Secret.generate_pair :anon, [sess.external_identifier]
        metadata.passphrase = passphrase if !passphrase.empty?
        secret.update_passphrase passphrase if !passphrase.empty?
        processed_value = case kind
        when :share
          secret_value.slice(0, 4999)
        when :generate
          @secret_value = Onetime::Utils.strand 12 # set secret_value too.
        end
        secret.original_size = secret_value.size
        secret.encrypt_value processed_value
        secret.save
        metadata.save
      end
      def redirect_uri
        if valid?
          ['/private/', metadata.key].join
        else
          '/?errno=%s' % [Onetime.errno(:nosecret)]
        end
      end
      def valid?
        metadata.valid? && secret.valid?
      end
    end
    
    class ShowSecret < OT::Logic::Base
      attr_reader :key, :passphrase, :continue
      attr_reader :secret, :show_secret, :secret_value
      def process_params
        @key = params[:key].to_s
        @secret = Onetime::Secret.load key
        @passphrase = params[:passphrase].to_s
        @continue = params[:continue] == 'true'
      end
      def raise_concerns
        raise OT::MissingSecret if secret.nil?
      end
      def process
        @show_secret = secret.state?(:new) && ((secret.has_passphrase? && secret.passphrase?(passphrase)) || continue)
        if show_secret 
          @secret_value = secret.can_decrypt? ? secret.decrypted_value : secret.value
          secret.viewed!
        end
      end
    end
    
    class ShowMetadata < OT::Logic::Base
      attr_reader :key
      attr_reader :metadata, :secret, :show_secret
      def process_params
        @key = params[:key].to_s
        @metadata = Onetime::Metadata.load key
      end
      def raise_concerns
        raise OT::MissingSecret if metadata.nil?
      end
      def process
        @secret = @metadata.load_secret
        # We temporarily store the raw passphrase when the private
        # secret is created so we can display it once. Here we 
        # update it with the encrypted one.
        unless metadata.state?(:viewed) || metadata.state?(:shared)
          secret.passphrase_temp = metadata.passphrase
          metadata.passphrase = secret.passphrase
          metadata.viewed!
          @show_secret = true
        end
      end
    end
  end
end