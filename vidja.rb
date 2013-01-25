require 'rubygems'
require 'bundler/setup'
require 'sinatra'
require 'sinatra/reloader' if development?
require 'aws/s3'
require 'dm-core'
require 'dm-validations'
require 'dm-migrations'
require 'zencoder'
require 'haml'
require 'json'
require 'canon'
require 'base64'
require 'net/http'

configure :development do
	DataMapper.setup(:default, 'sqlite:vidja.db')
	DataMapper::Logger.new(STDOUT, :debug)
end

configure :production do
	DataMapper.setup(:default, 'mysql://database@localhost/vidja')
	DataMapper::Logger.new('/home/deploy/dm.log', :debug)
	use CanonicalHost, 'thevidja.com'
	#set :show_exceptions, true
	
end

## Models
class Video
	include DataMapper::Resource
	
	property :id,					Serial
	property :created_at,	DateTime
	property :b36id,			String,		:default => 0
	
	property :jobid,			Integer,	:default => 0
	property :webmid,			Integer,	:default => 0
	property :mp4id,			Integer,	:default => 0
	property :ogvid,			Integer,	:default => 0
	
	property :mainstatus,	String
	property :webmstatus,	String
	property :mp4status,	String
	property :ogvstatus,	String
	
end

class Token
	include DataMapper::Resource
	
	property :id,					Serial
	property :created_at,	DateTime
	property :token,			Text,   :lazy => false
	
	belongs_to :user
	
	
end

DataMapper.finalize
#DataMapper.auto_migrate!

AWS::S3::Base.establish_connection!(
	:access_key_id	=>	'ACCESS_KEY',
	:secret_access_key => 'SECRET_KEY'
)


Zencoder.api_key = 'ZENCODER_API_KEY'

def logged_in?
	tokenKey = session["token"]
	token = Token.first(:token => tokenKey)
	if token != nil
		return token.user
	else
		return nil
	end
end

get '/' do
	f = File.open("slogans.txt")
	num = 17
  @slogan = f.readlines[rand(num)]
	#@slogan = "it was fun while it lasted. :("
	@pageTitle = "vidja! #{@slogan}"
	haml :index
end

post '/upload' do
	filename = params['qqfile']
	
	filename = Time.now.strftime("%m.%d.%Y.%H.%M.%S") + '-' + filename
	
	newf = File.open('public/tmp/' + filename, "wb")
	str = request.body.read
	newf.write(str)
	newf.close
	
	video = Video.new(:created_at => Time.now)
	if video.save
		#fantastic
	else
		video.errors.each { |e|
			DataMapper.logger.push(e.to_s)
		}
	end
	video.b36id = Time.now.strftime("%H%M%S#{video.id}").to_i.to_s(36)
	if video.save
		#fantastic
	else
		video.errors.each { |e|
			DataMapper.logger.push(e.to_s)
		}
	end
	response = Zencoder::Job.create({
		:input=>"http://thevidja.com/tmp/#{filename}",
		:outputs=>[
			{
				:label=>"mp4",
				:base_url=>"s3://vidja/#{video.id}/",
				:filename=>"#{video.b36id}.mp4",
				:notifications=>[
				{
					:format=>"json",
					:url=>"http://thevidja.com/status"
				}],
				:public=>1,
				:video_codec=>"h264",
				:quality=>3,
				:speed=>3,
				:width=>640,
				:height=>480,
				:aspect_mode=>"preserve",
				:audio_codec=>"aac",
				:audio_quality=>3
			},
			{
				:label=>"ogv",
				:base_url=>"s3://vidja/#{video.id}/",
				:filename=>"#{video.b36id}.ogv",
				:notifications=>[
				{
					:format=>"json",
					:url=>"http://thevidja.com/status"
				}],
				:public=>1,
				:video_codec=>"theora",
				:quality=>3,
				:speed=>3,
				:width=>640,
				:height=>480,
				:aspect_mode=>"preserve",
				:audio_codec=>"vorbis",
				:audio_quality=>3
			},
			{
				:label=>"webm",
				:base_url=>"s3://vidja/#{video.id}/",
				:filename=>"#{video.b36id}.webm",
				:notifications=>[
				{
					:format=>"json",
					:url=>"http://thevidja.com/status"
				}],
				:public=>1,
				:video_codec=>"vp8",
				:quality=>3,
				:speed=>3,
				:width=>640,
				:height=>480,
				:aspect_mode=>"preserve",
				:audio_codec=>"vorbis",
				:audio_quality=>3,
				:thumbnails=>{
					:number=>1,
					:size=>"640x480",
					:base_url=>"s3://vidja/#{video.id}/"
				}
			}
		],
		:api_key=>"ZENCODER_API"
	})
	
	if response.success?
		video.mp4id = response.body['outputs'][0]['id']
		video.ogvid = response.body['outputs'][1]['id']
		video.webmid = response.body['outputs'][2]['id']
		video.jobid = response.body['id']
		if video.save
			#fantastic
		else
			video.errors.each { |e|
				DataMapper.logger.push(e.to_s)
			}
		end
		'{"success":true,"filename":"' + filename + '","b36id":"' + video.b36id + '"}'
	else
		video.mainstatus = "failed"
		if video.save
			#fantastic
		else
			video.errors.each { |e|
				DataMapper.logger.push(e.to_s)
			}
		end
		'{"success":false,"filename":"' + filename + '","b36id":"' + video.b36id + '"}'	
	end
	
	#'{"success":true,"filename":"' + filename + '"}'
end

post '/status' do
	raw = request.env["rack.input"].read
	json = JSON.parse(raw)
	video = Video.first(:jobid => json['job']['id'])
	if json['output']['state'] == "failed"
		video.mainstatus = "failed"
	end
	if json['output']['label'] == "mp4"
		video.mp4status = json['output']['state']
	elsif json['output']['label'] == "ogv"
		video.ogvstatus = json['output']['state']
	elsif json['output']['label'] == "webm"
		video.webmstatus = json['output']['state']
	end
	
	if (video.mp4status == "finished") && (video.ogvstatus == "finished") && (video.webmstatus == "finished")
		video.mainstatus = "finished"
	end
	if video.save
		#fantastic
	else
		video.errors.each { |e|
			DataMapper.logger.push(e.to_s)
		}
	end
end

get '/about' do
	@pageTitle = 'aboot us'
	haml :about
end

get '/v/*' do
	b36id = params["splat"][0]
	@video = Video.first(:b36id => b36id)
	if @video != nil
		@pageTitle = 'vidja! this is a video'
		if @video.mainstatus == "finished"
			haml :viewVideo
		elsif @video.mainstatus == "failed"
			haml :failedVideo
		else
			@mp4response = Zencoder::Output.progress(@video.mp4id)
			@ogvresponse = Zencoder::Output.progress(@video.ogvid)
			@webmresponse = Zencoder::Output.progress(@video.webmid)
			haml :processingVideo
		end
	else
		status 404
	end
end

get '/tos' do
	haml :tos
end

get '/contact' do
	haml :contact
end
get '/donate' do
	@pageTitle = 'vidja! help us!'
	haml :donate
end

get '/donate/thanks' do
	@pageTitle = 'vidja! you\'re the best!'
	haml :donateThanks
end

not_found do
	@pageTitle = 'vidja! 404!'
	haml :'404'
end
error do
	@pageTitle = 'vidja! error\'d!'
	haml :'500'
end
