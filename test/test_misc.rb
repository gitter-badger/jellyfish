
require 'jellyfish/test'

describe Jellyfish do
  behaves_like :jellyfish

  app = Class.new{
    include Jellyfish
    handle_exceptions false
    get('/boom'){ halt 'string' }
    get
  }.new

  should 'match wildcard' do
    get('/a', app).should.eq [200, {}, ['']]
    get('/b', app).should.eq [200, {}, ['']]
  end

  should 'accept to_path body' do
    a = Class.new{
      include Jellyfish
      get{ File.open(__FILE__) }
    }.new
    get('/', a).last.to_path.should.eq __FILE__
  end

  should 'raise TypeError if we try to respond non-Response or non-Rack' do
    begin
      get('/boom', app)
    rescue TypeError => e
      e.message.should.include '"string"'
    end
  end
end
