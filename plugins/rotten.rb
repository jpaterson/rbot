# rotten tomatoes
# by chetan sarva <cs@pixelcop.net> 2007-01-23
#
# if given a movie title, finds the rating for that movie, or 
# displays ratings for movies opening this week

require 'rexml/document'
require 'uri/common'
require '0lib_rbot'
require 'scrapi'
require 'ostruct'


Struct.new("Movie", :title, :link, :percent, :rating, :desc, :count, :fresh, :rotten, :release)

class RottenPlugin < Plugin

	include REXML
	include PluginLib

	def initialize
		super
		@rss = "http://i.rottentomatoes.com/syndication/rss/"
		@search = "http://www.rottentomatoes.com/search/full_search.php?search="
		@site = "http://www.rottentomatoes.com"
	end

	def help(plugin, topic="")
		return "rotten|rt [num] [opening|upcoming|top|current|<movie title>] => ratings for movies opening this week, rt top => ratings for the current top movies, rt upcoming => advance ratings for upcoming movies, rt current => top recent releases, rt <movie title> => lookup rating for a movie"
	end

	def rotten(m, params, url = false)
	
		num = params[:num].to_i if params[:num]
		
    	movie = params[:movie]
    	movie = movie.join(" ").downcase if not movie.nil?
    	
		if movie.nil? or movie.length == 0 or movie == 'opening' or movie == 'new'
			opening m, params, @rss + "opening.xml", num
		elsif movie == 'upcoming'
			opening m, params, @rss + "upcoming.xml"
		elsif movie == 'top'
			opening m, params, @rss + "top_movies.xml"
		elsif movie == 'current'
			opening m, params, @rss + "in_theaters.xml"
		else
			search m, params, movie, url
		end
    
	end
	
	def rturl(m, params)
		
		rotten m, params, true
		
	end
	
	def search(m, params, movie, show_url = false)
		
		# first, search in the complete xml feed to see if its a current movie
		info = search_xml(m, movie, show_url)

        # try searching the site		
		info = search_site(m, movie, show_url) if info.nil?
		
		# couldn't find anything
		return m.reply sprintf("`%s' not found", movie) if info.nil?

        m.reply sprintf("%s - %s%% = %s (%s/%s) %s", info.title, info.rating, info.status, info.fresh, info.total, info.link)

	end
	
	def search_xml(m, movie, show_url)
	
    	xml = fetchurl(@rss + "complete_movies.xml")
		unless xml
			m.reply "faild to fetch feed"
			return nil
		end

		doc = Document.new xml
		unless doc
			m.reply "rotten parse failed (invalid xml)"
			return nil
		end
		
		begin
		
			title = percent = rating = link = desc = release = nil
			doc.elements.each("rss/channel/item") {|e|			
				
				title = e.elements["title"].text
				link = e.elements["link"].text
				
				if not e.elements["RTmovie:tomatometer_percent"].text.nil?
					# movie has a rating
					title = title.slice(title.index(' ')+1, title.length) if title.include? '%'
				end
				
				if title.downcase == movie or title.downcase.include? movie
					return get_movie_info(m, title, link, show_url)
				end
				
			}
		
		rescue => ex
			error ex.inspect
			error ex.backtrace.join("\n")			
		end
		
		return nil
	
	end
	
	def search_site(m, movie, show_url)
	
		# second, try searching for the movie title
		html = fetchurl(@search + movie)
		
		movie_scraper = Scraper.define do
			
			process "td.title > p > a", :title => :text
			process "td.title > p > a", :url => "@href"			
			
			result :title, :url
		
		end
		
		movies_scraper = Scraper.define do
		
			array :movies
			process "table.proViewTbl td.title", :movies => movie_scraper
			result :movies
			
		end
		
		movies = movies_scraper.scrape(html)
		
		movies.each { |_m| 
			if _m.title.downcase == movie then
				return get_movie_info(m, _m.title, @site + _m.url, show_url)
			end
		}
		
		# no exact match, let's use the first result.. 
		return get_movie_info(m, movies[0].title, @site + movies[0].url, show_url)
	
	end
	
	def get_movie_info(m, title, link, show_url = false)
	
		html = fetchurl(link)
		if html.nil?
			debug "error fetching " + link
			return
		end
		
		movie_scraper = Scraper.define do
			
			array :info
			
			process "div#tomatometer_data", :ratings => :text
			process "div#tomatometer_score > span.percent", :rating => :text
			process "div#bubble_topCritics", :rating_top => :text
			process "div#movie_stats span", :info => :text
			
			result :ratings, :rating, :rating_top, :info
			
		end
		
		info = movie_scraper.scrape(html)
		movie_info = OpenStruct.new({:title => title,
									 :rating => info.rating.to_i,
									 :rating_top => info.rating_top.to_i,
									 :link => link })
		
		if info.ratings.match(/Reviews Counted: ?(\d+)/) then
            movie_info.total = $1.to_i
        end
        
		if info.ratings.match(/Fresh: ?(\d+)/) then
            movie_info.fresh = $1.to_i
		end

		if info.ratings.match(/Rotten: ?(\d+)/) then
            movie_info.rotten = $1.to_i
        end
		
		if info.ratings.match(/Average Rating: ?(.*)/) then
            movie_info.average = $1
        end
        
		movie_info.runtime     = info.info[1]
		movie_info.relase_date = info.info[3]
		movie_info.box_office  = info.info[5]
		
		movie_info.status = movie_info.rating >= 60 ? 'Fresh' : 'Rotten'
		
		return movie_info
	
	end
	

	
	# print opening movies and their scores
	def opening(m, params, url, num = 5)

        warning num
        num -= 1
	    num = 0 if num < 0

    	xml = fetchurl(url)
		unless xml
			m.reply "faild to fetch feed"
			return
		end
		
        begin
		    doc = Document.new xml
        rescue => ex
            if xml.include? '<html>' then
			    return m.reply "rottentomatoes rss feeds are currently down"
            else
                return m.reply "error parsing feed: " + ex
            end
		end
		
		begin
		
		matches = Array.new
		doc.elements.each("rss/channel/item") {|e|			
			
			title = e.elements["title"].text
			
			if not e.elements["RTmovie:tomatometer_percent"].text.nil?
				# movie has a rating
				title = title.slice(title.index(' ')+1, title.length) if title.include? '%'
				percent = e.elements["RTmovie:tomatometer_percent"].text + "%"
				rating = e.elements["RTmovie:tomatometer_rating"].text
			else
				# not yet rated
				percent = "n/a"
				rating = ""
			end

			matches << sprintf("%s - %s %s", title, percent, rating)
			
		}
		
		rescue => ex
			error ex.inspect
			error ex.backtrace.join("\n")
			
		end
		
        (0..num).each { |i|
			m.reply matches[i]
		}
	
	end

end

plugin = RottenPlugin.new
plugin.map 'rotten [:num] *movie', :action => 'rotten', :defaults => { :movie => nil, :num => 5 }, :requirements => { :num => %r|\d+| }

plugin.map 'rt [:num] *movie', :action => 'rotten', :defaults => { :movie => nil, :num => 5 }, :requirements => { :num => %r|\d+| }

plugin.map 'rturl *movie', :action => 'rturl', :defaults => { :movie => nil }