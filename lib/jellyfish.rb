
module Jellyfish
  autoload :VERSION , 'jellyfish/version'
  autoload :Sinatra , 'jellyfish/sinatra'
  autoload :NewRelic, 'jellyfish/newrelic'

  autoload :MultiActions    , 'jellyfish/multi_actions'
  autoload :NormalizedParams, 'jellyfish/normalized_params'
  autoload :NormalizedPath  , 'jellyfish/normalized_path'

  autoload :ChunkedBody, 'jellyfish/chunked_body'

  GetValue = Object.new

  class Response < RuntimeError
    def headers
      @headers ||= {'Content-Type' => 'text/html'}
    end

    def body
      @body ||= [File.read("#{Jellyfish.public_root}/#{status}.html")]
    end
  end

  class InternalError < Response; def status; 500; end; end
  class NotFound      < Response; def status; 404; end; end
  class Found         < Response # this would be raised in redirect
    attr_reader :url
    def initialize url; @url = url                             ; end
    def status        ; 302                                    ; end
    def headers       ; super.merge('Location' => url)         ; end
    def body          ; super.map{ |b| b.gsub('VAR_URL', url) }; end
  end

  # -----------------------------------------------------------------

  class Controller
    attr_reader :routes, :jellyfish, :env
    def initialize routes, jellyfish
      @routes, @jellyfish = routes, jellyfish
      @status, @headers, @body = nil
    end

    def call env
      @env = env
      block_call(*dispatch)
    end

    def block_call argument, block
      val = instance_exec(argument, &block)
      [status || 200, headers || {}, body || with_each(val || '')]
    rescue LocalJumpError
      jellyfish.log("Use `next' if you're trying to `return' or" \
                    " `break' from the block.", env['rack.errors'])
      raise
    end

    def request  ; @request ||= Rack::Request.new(env); end
    def forward  ; raise(Jellyfish::NotFound.new)     ; end
    def found url; raise(Jellyfish::   Found.new(url)); end
    alias_method :redirect, :found

    def path_info     ; env['PATH_INFO']      || '/'  ; end
    def request_method; env['REQUEST_METHOD'] || 'GET'; end

    %w[status headers].each do |field|
      module_eval <<-RUBY
        def #{field} value=GetValue
          if value == GetValue
            @#{field}
          else
            @#{field} = value
          end
        end
      RUBY
    end

    def body value=GetValue
      if value == GetValue
        @body
      elsif value.nil?
        @body = value
      else
        @body = with_each(value)
      end
    end

    def headers_merge value
      if headers.nil?
        headers(value)
      else
        headers(headers.merge(value))
      end
    end

    private
    def actions
      routes[request_method.downcase] || raise(Jellyfish::NotFound.new)
    end

    def dispatch
      actions.find{ |(route, block)|
        case route
        when String
          break route, block if route == path_info
        else#Regexp, using else allows you to use custom matcher
          match = route.match(path_info)
          break match, block if match
        end
      } || raise(Jellyfish::NotFound.new)
    end

    def with_each value
      if value.respond_to?(:each) then value else [value] end
    end
  end

  # -----------------------------------------------------------------

  module DSL
    def routes  ; @routes   ||= {}; end
    def handlers; @handlers ||= {}; end
    def handle exception, &block; handlers[exception] = block; end
    def handle_exceptions value=GetValue
      if value == GetValue
        @handle_exceptions
      else
        @handle_exceptions = value
      end
    end

    def controller_include *value
      (@controller_include ||= []).push(*value)
    end

    def controller value=GetValue
      if value == GetValue
        @controller ||= controller_inject(
          const_set(:Controller, Class.new(Controller)))
      else
        @controller   = controller_inject(value)
      end
    end

    def controller_inject value
      controller_include.
        inject(value){ |ctrl, mod| ctrl.__send__(:include, mod) }
    end

    %w[options get head post put delete patch].each do |method|
      module_eval <<-RUBY
        def #{method} route=//, &block
          raise TypeError.new("Route \#{route} should respond to :match") \
            unless route.respond_to?(:match)
          (routes['#{method}'] ||= []) << [route, block]
        end
      RUBY
    end

    def inherited sub
      sub.handle_exceptions(handle_exceptions)
      sub.controller_include(*controller_include)
      [:handlers, :routes].each{ |m|
        val = __send__(m).inject({}){ |r, (k, v)| r[k] = v.dup; r }
        sub.__send__(m).replace(val) # dup the routing arrays
      }
    end
  end

  # -----------------------------------------------------------------

  def initialize app=nil; @app = app; end

  def call env
    ctrl = self.class.controller.new(self.class.routes, self)
    ctrl.call(env)
  rescue NotFound => e # forward
    if app
      begin
        app.call(env)
      rescue Exception => e
        handle(ctrl, e, env['rack.errors'])
      end
    else
      handle(ctrl, e)
    end
  rescue Exception => e
    handle(ctrl, e, env['rack.errors'])
  end

  def log_error e, stderr
    return unless stderr
    stderr.puts("[#{self.class.name}] #{e.inspect} #{e.backtrace}")
  end

  def log msg, stderr
    return unless stderr
    stderr.puts("[#{self.class.name}] #{msg}")
  end

  private
  def handle ctrl, e, stderr=nil
    handler = self.class.handlers.find{ |klass, block|
      break block if e.kind_of?(klass)
    }
    if handler
      ctrl.block_call(e, handler)
    elsif !self.class.handle_exceptions
      raise e
    elsif e.kind_of?(Response) # InternalError ends up here if no handlers
      [e.status, e.headers, e.body]
    else # fallback and see if there's any InternalError handler
      log_error(e, stderr)
      handle(ctrl, InternalError.new)
    end
  end

  # -----------------------------------------------------------------

  def self.included mod
    mod.__send__(:extend, DSL)
    mod.__send__(:attr_reader, :app)
    mod.handle_exceptions(true)
  end

  # -----------------------------------------------------------------

  module_function
  def public_root
    "#{File.dirname(__FILE__)}/jellyfish/public"
  end
end
