# OpenSSL and Base64 are required to support signed_request
require 'openssl'
require 'base64'

module Koala
  module Facebook
    
    DIALOG_HOST = "www.facebook.com"
    
    class OAuth
      attr_reader :app_id, :app_secret, :oauth_callback_url
      def initialize(app_id, app_secret, oauth_callback_url = nil)
        @app_id = app_id
        @app_secret = app_secret
        @oauth_callback_url = oauth_callback_url
      end
      
      def get_user_info_from_cookie(cookie_hash)
        # Parses the cookie set Facebook's JavaScript SDK.
        # You can pass Rack/Rails/Sinatra's cookie hash directly to this method.
        #
        # If the user is logged in via Facebook, we return a dictionary with the
        # keys "uid" and "access_token". The former is the user's Facebook ID,
        # and the latter can be used to make authenticated requests to the Graph API.
        # If the user is not logged in, we return None.

        if signed_cookie = cookie_hash["fbsr_#{@app_id}"]
          parse_signed_cookie(signed_cookie)
        elsif unsigned_cookie = cookie_hash["fbs_#{@app_id}"]
          parse_unsigned_cookie(unsigned_cookie)
        end
      end
      alias_method :get_user_info_from_cookies, :get_user_info_from_cookie

      def get_user_from_cookie(cookies)
        if info = get_user_info_from_cookies(cookies)
          # signed cookie has user_id, unsigned cookie has uid
          string = info["user_id"] || info["uid"]
        end
      end
      alias_method :get_user_from_cookies, :get_user_from_cookie

      # URLs
      
      def url_for_oauth_code(options = {})
        # for permissions, see http://developers.facebook.com/docs/authentication/permissions
        if permissions = options.delete(:permissions)
          options[:scope] = permissions.is_a?(Array) ? permissions.join(",") : permissions
        end
        url_options = {:client_id => @app_id}.merge(options)
        
        # Creates the URL for oauth authorization for a given callback and optional set of permissions
        build_url("https://#{GRAPH_SERVER}/oauth/authorize", true, url_options)
      end

      def url_for_access_token(code, options = {})
        # Creates the URL for the token corresponding to a given code generated by Facebook
        url_options = {
          :client_id => @app_id, 
          :code => code,
          :client_secret => @app_secret
        }.merge(options)
        build_url("https://#{GRAPH_SERVER}/oauth/access_token", true, url_options)
      end

      def url_for_dialog(dialog_type, options = {})
        # some endpoints require app_id, some client_id, supply both doesn't seem to hurt
        url_options = {:app_id => @app_id, :client_id => @app_id}.merge(options)        
        build_url("http://#{DIALOG_HOST}/dialog/#{dialog_type}", true, url_options)
      end
      
      # access tokens
      
      def get_access_token_info(code, options = {})
        # convenience method to get a parsed token from Facebook for a given code
        # should this require an OAuth callback URL?
        get_token_from_server({:code => code, :redirect_uri => options[:redirect_uri] || @oauth_callback_url}, false, options)
      end

      def get_access_token(code, options = {})
        # upstream methods will throw errors if needed
        if info = get_access_token_info(code, options)
          string = info["access_token"]
        end
      end

      def get_app_access_token_info(options = {})
        # convenience method to get a the application's sessionless access token
        get_token_from_server({:type => 'client_cred'}, true, options)
      end

      def get_app_access_token(options = {})
        if info = get_app_access_token_info(options)
          string = info["access_token"]
        end
      end

      # Originally provided directly by Facebook, however this has changed
      # as their concept of crypto changed. For historic purposes, this is their proposal:
      # https://developers.facebook.com/docs/authentication/canvas/encryption_proposal/
      # Currently see https://github.com/facebook/php-sdk/blob/master/src/facebook.php#L758
      # for a more accurate reference implementation strategy.
      def parse_signed_request(input)
        encoded_sig, encoded_envelope = input.split('.', 2)
        raise 'SignedRequest: Invalid (incomplete) signature data' unless encoded_sig && encoded_envelope

        signature = base64_url_decode(encoded_sig).unpack("H*").first
        envelope = MultiJson.decode(base64_url_decode(encoded_envelope))

        raise "SignedRequest: Unsupported algorithm #{envelope['algorithm']}" if envelope['algorithm'] != 'HMAC-SHA256'

        # now see if the signature is valid (digest, key, data)
        hmac = OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA256.new, @app_secret, encoded_envelope)
        raise 'SignedRequest: Invalid signature' if (signature != hmac)

        envelope
      end

      # from session keys
      def get_token_info_from_session_keys(sessions, options = {})
        # fetch the OAuth tokens from Facebook
        response = fetch_token_string({
          :type => 'client_cred',
          :sessions => sessions.join(",")
        }, true, "exchange_sessions", options)

        # Facebook returns an empty body in certain error conditions
        if response == ""
          raise APIError.new({
            "type" => "ArgumentError",
            "message" => "get_token_from_session_key received an error (empty response body) for sessions #{sessions.inspect}!"
          })
        end

        MultiJson.decode(response)
      end

      def get_tokens_from_session_keys(sessions, options = {})
        # get the original hash results
        results = get_token_info_from_session_keys(sessions, options)
        # now recollect them as just the access tokens
        results.collect { |r| r ? r["access_token"] : nil }
      end

      def get_token_from_session_key(session, options = {})
        # convenience method for a single key
        # gets the overlaoded strings automatically
        get_tokens_from_session_keys([session], options)[0]
      end

      protected

      def get_token_from_server(args, post = false, options = {})
        # fetch the result from Facebook's servers
        result = fetch_token_string(args, post, "access_token", options)

        # if we have an error, parse the error JSON and raise an error
        raise APIError.new((MultiJson.decode(result)["error"] rescue nil) || {}) if result =~ /error/

        # otherwise, parse the access token
        parse_access_token(result)
      end

      def parse_access_token(response_text)
        components = response_text.split("&").inject({}) do |hash, bit|
          key, value = bit.split("=")
          hash.merge!(key => value)
        end
        components
      end
      
      def parse_unsigned_cookie(fb_cookie)
        # remove the opening/closing quote
        fb_cookie = fb_cookie.gsub(/\"/, "")

        # since we no longer get individual cookies, we have to separate out the components ourselves
        components = {}
        fb_cookie.split("&").map {|param| param = param.split("="); components[param[0]] = param[1]}

        # generate the signature and make sure it matches what we expect
        auth_string = components.keys.sort.collect {|a| a == "sig" ? nil : "#{a}=#{components[a]}"}.reject {|a| a.nil?}.join("")
        sig = Digest::MD5.hexdigest(auth_string + @app_secret)
        sig == components["sig"] && (components["expires"] == "0" || Time.now.to_i < components["expires"].to_i) ? components : nil
      end
      
      def parse_signed_cookie(fb_cookie)
        components = parse_signed_request(fb_cookie)
        if (code = components["code"]) && token_info = get_access_token_info(code, :redirect_uri => '')
          components.merge(token_info)
        else
          nil
        end
      end

      def fetch_token_string(args, post = false, endpoint = "access_token", options = {})
        Koala.make_request("/oauth/#{endpoint}", {
          :client_id => @app_id,
          :client_secret => @app_secret
        }.merge!(args), post ? "post" : "get", {:use_ssl => true}.merge!(options)).body
      end

      # base 64
      # directly from https://github.com/facebook/crypto-request-examples/raw/master/sample.rb
      def base64_url_decode(str)
        str += '=' * (4 - str.length.modulo(4))
        Base64.decode64(str.tr('-_', '+/'))
      end
      
      def build_url(base, require_redirect_uri = false, url_options = {})
        if require_redirect_uri && !(url_options[:redirect_uri] ||= url_options.delete(:callback) || @oauth_callback_url)          
          raise ArgumentError, "url_for_dialog must get a callback either from the OAuth object or in the parameters!"
        end
        
        "#{base}?#{Koala::HTTPService.encode_params(url_options)}"
      end
    end
  end
end
