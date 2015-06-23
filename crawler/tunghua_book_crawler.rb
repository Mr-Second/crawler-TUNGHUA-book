require 'pry'
require 'json'
require 'iconv'
require 'crawler_rocks'

require 'thread'
require 'thwait'

class TunghuaBookCrawler
  include CrawlerRocks::DSL

  def initialize
    @search_url = "http://www.tunghua.com.tw/search_ok.php"
    @ic = Iconv.new("utf-8//translit//IGNORE","big5")
  end

  def books(detail: false)
    @books = {}
    @threads = []

    visit @search_url
    page_num = @doc.css('.style8').text.match(/共\s*?(?<count>\d+)\s*項合乎規則/)[1].to_i / 30 + 1

    # (0...5).each do |i|
    (0...page_num).each do |i|
      sleep(1) until (
        @threads.delete_if { |t| !t.status };  # remove dead (ended) threads
        @threads.count < (ENV['MAX_THREADS'] || 25)
      )
      @threads << Thread.new do
        r = RestClient.post @search_url, {
          page_cntl: i
        }

        doc = Nokogiri::HTML(@ic.iconv r)
        doc.css('tr.style16').each do |row|
          datas = row.css('td')

          url = datas[3] && (!datas[3].css('a').empty? ? datas[3].css('a')[0][:href] : nil)
          url = url && URI.join(@search_url, url).to_s

          internal_code = nil
          internal_code = url && url.match(/(?<=oid=)\d+/).to_s

          @books[internal_code] = {
            isbn_10: datas[0] && datas[0].text.strip,
            isbn: datas[1] && datas[1].text.strip,
            author: datas[2] && datas[2].text.strip,
            name: datas[3] && datas[3].text.strip,
            price: datas[5] && datas[5].text.gsub(/[^\d]/, '').to_i,
            internal_code: internal_code,
            url: url
          }
        end # end each row
        print "#{i}|"
      end # end Thread
    end # end each page

    # about 2-3 minues to finish 200 pages book list
    ThreadsWait.all_waits(*@threads)

    # then we crawl details, including publisher / external_image_url / edition
    @detail_threads = []
    if detail
      puts "Crawl detail pages"
      @books.each_with_index do |(internal_code, book), i|
        sleep(1) until (
          @detail_threads.delete_if { |t| !t.status };  # remove dead (ended) threads
          @detail_threads.count < (ENV['MAX_THREADS'] || 25)
        )
        @detail_threads << Thread.new do
          doc = Nokogiri::HTML(@ic.iconv(RestClient.get(book[:url])))

          detail_table = doc.css('table[width="100%"][border="0"][cellpadding="4"]')[0]
          rows = detail_table.css('tr')

          publisher = nil; external_image_url = nil; edition = nil;

          pub_row = rows.find {|row| row.text.include?('出版商')}
          publisher = pub_row && pub_row.css('td').last.text

          edi_row = rows.find {|row| row.text.include?('版次')}
          edition = edi_row && edi_row.css('td').last.text.to_i

          external_image_url = doc.css('img').map {|img| img[:src]}.find {|src| src.include?("http://www.tunghua.com.tw//upload")}

          @books[internal_code][:publisher] = publisher
          @books[internal_code][:edition] = edition
          @books[internal_code][:external_image_url] = external_image_url
        end # end thread do
        print "#{i}|"
      end # each book
    end # crawl detail
    ThreadsWait.all_waits(*@detail_threads)

    @books.map{|k, v| v}
  end # end books

end

cc = TunghuaBookCrawler.new
File.write('donhwa_books.json', JSON.pretty_generate(cc.books(detail: true)))

