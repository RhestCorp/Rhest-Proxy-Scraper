require 'net/http'
require 'uri'
require 'nokogiri'
require 'socket' # TCP bağlantıları için bu piçe ihtiyacımız var
require 'timeout' # Bağlantı zaman aşımı için
require 'socksify/http' # SOCKS5 proxy üzerinden HTTP isteği yapmak için

class ProxyScrapper
  attr_reader :proxies

  def initialize
    @proxies = {
      http: [],
      https: [], # HTTPS'i de ayrı tutalım, daha net olsun
      socks5: [],
      unknown: []
    }
    @proxy_sources = [
      { url: "https://free-proxy-list.net/", type: :html_table, expected_types: [:http, :https] },
      { url: "https://www.socks-proxy.net/", type: :html_table, expected_types: [:socks5] },
      { url: "https://proxyscrape.com/free-proxy-list", type: :html_table, expected_types: [:http, :https, :socks4, :socks5] },
      { url: "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt", type: :raw_text, expected_types: [:http] },
      { url: "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/socks5.txt", type: :raw_text, expected_types: [:socks5] },
      { url: "https://raw.githubusercontent.com/jetkai/proxy-list/main/online-proxies/txt/proxies-http.txt", type: :raw_text, expected_types: [:http] } # Yeni bir HTTP kaynağı
    ]
    @test_target_url_http = URI.parse("http://www.google.com") # HTTP proxy'leri test etmek için
    @test_target_url_socks = URI.parse("https://www.whatsmyip.org/") # SOCKS5 proxy'leri için daha iyi bir test, HTTPS destekli
    @timeout_seconds = 5 # Her proxy testi için maksimum 5 saniye bekle, sikinin keyfine göre ayarla
    @retries_per_proxy = 1 # Her proxy için 1 deneme yeter, çok takılma
  end

  # Bir URL'den içeriği çeken sikik bir metod
  def fetch_content(url, proxy_ip = nil, proxy_port = nil, proxy_type = nil)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE # Sertifika doğrulamasını siktir et

    if proxy_ip && proxy_port
      puts "Proxy kullanarak içeriği çekiyorum: #{proxy_ip}:#{proxy_port} (#{proxy_type.to_s.upcase})" if $DEBUG_MODE
      if proxy_type == :socks5
        http.socks_version = 5
        Net::HTTP.socks_address = proxy_ip
        Net::HTTP.socks_port = proxy_port.to_i
      elsif proxy_type == :http || proxy_type == :https
        http = Net::HTTP.new(uri.host, uri.port, proxy_ip, proxy_port.to_i)
        http.use_ssl = (uri.scheme == 'https')
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      else
        puts "Bilinmeyen proxy tipi amına koyayım, doğrudan bağlanıyorum." if $DEBUG_MODE
      end
    end

    request = Net::HTTP::Get.new(uri.request_uri)
    response = nil

    begin
      Timeout.timeout(@timeout_seconds) do
        response = http.request(request)
      end
    rescue Timeout::Error
      puts "Bağlantı zaman aşımına uğradı: #{url}" if $DEBUG_MODE
      return nil
    rescue StandardError => e
      puts "URL'yi çekerken bir siklik oldu #{url}: #{e.message}" if $DEBUG_MODE
      return nil
    ensure
      # SOCKS ayarlarını sıfırlamak önemli, diğer istekleri sikmemek için
      if proxy_type == :socks5
        Net::HTTP.socks_address = nil
        Net::HTTP.socks_port = nil
      end
    end

    unless response && response.code == '200'
      puts "bu orospu çocuğundan #{url} içerik çekilemedi! HTTP Kodu: #{response&.code}" if $DEBUG_MODE
      return nil
    end
    response.body
  end

  # HTML tablolarından proxy'leri ayıklayan metod
  def parse_html_table(html_content, expected_types)
    doc = Nokogiri::HTML(html_content)
    proxies_found = []
    doc.css('table.dataTable tbody tr').each do |row|
      cols = row.css('td')
      next if cols.empty?

      ip = cols[0]&.text&.strip
      port = cols[1]&.text&.strip
      country = cols[2]&.text&.strip
      anon_level = cols[4]&.text&.strip
      ssl = cols[6]&.text&.strip # HTTPS var mı yok mu?

      next unless ip && port && ip =~ /\A\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\z/ # IP formatı doğru mu bak amına koyayım

      proxy_address = "#{ip}:#{port}"
      type = determine_proxy_type_from_flags(ssl, anon_level, expected_types)
      proxies_found << { address: proxy_address, type: type, country: country }
    end
    proxies_found
  rescue StandardError => e
    puts "HTML parse ederken bir bokluk oldu amına koyayım: #{e.message}" if $DEBUG_MODE
    []
  end

  # Ham metin dosyalarından proxy'leri ayıklayan metod
  def parse_raw_text(text_content, expected_types)
    proxies_found = []
    text_content.each_line do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#')

      if line =~ /(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}):(\d+)/
        ip = $1
        port = $2
        proxy_address = "#{ip}:#{port}"
        type = expected_types.first || :unknown
        proxies_found << { address: proxy_address, type: type }
      end
    end
    proxies_found
  rescue StandardError => e
    puts "Ham metin parse ederken bir bokluk oldu amına koyayım: #{e.message}" if $DEBUG_MODE
    []
  end

  # Proxy türünü belirleyen sikindirik bir mantık
  def determine_proxy_type_from_flags(ssl_flag, anon_level, expected_types_from_source)
    if expected_types_from_source.include?(:socks5)
      return :socks5
    elsif expected_types_from_source.include?(:http) || expected_types_from_source.include?(:https)
      if ssl_flag && ssl_flag.downcase == 'yes'
        return :https
      else
        return :http
      end
    end
    :unknown
  end

  # Tüm kaynaklardan proxy'leri sömüren ana metod
  def scrape_all_proxies
    puts "Sikik tüm proxy kaynaklarını sömürüyorum amına koyayım... Bu biraz sürecek, bekle!"
    # Önce mevcut proxy'leri temizleyelim, yoksa sürekli üstüne ekler
    @proxies = { http: [], https: [], socks5: [], unknown: [] }

    @proxy_sources.each_with_index do |source, index|
      puts "Kahrolasıca #{source[:url]} adresinden içerik çekiliyor (Kaynak #{index + 1}/#{@proxy_sources.size})"
      content = fetch_content(source[:url])
      next unless content

      found_proxies = []
      case source[:type]
      when :html_table
        found_proxies = parse_html_table(content, source[:expected_types])
      when :raw_text
        found_proxies = parse_raw_text(content, source[:expected_types])
      else
        puts "Bilinmeyen kaynak tipi amına koyayım: #{source[:type]}"
        next
      end

      found_proxies.each do |proxy|
        type = proxy[:type] || :unknown
        @proxies[type] << proxy[:address] unless @proxies[type].include?(proxy[:address])
      end
      puts "Kaynak #{index + 1}'den #{found_proxies.size} adet proxy bulundu ve eklendi!"
    end
    @proxies.each { |type, list| @proxies[type] = list.uniq } # Dublikateleri siktir et
    puts "Toplamda #{ @proxies.values.flatten.size } adet proxy toplandı. Helal olsun sana piç!"
  end

  # Bulunan proxy'leri dosyalara kaydeden sikindirik metod
  def save_proxies_to_files(directory = "proxies")
    Dir.mkdir(directory) unless File.exist?(directory)

    @proxies.each do |type, list|
      next if list.empty?
      filename = File.join(directory, "#{type}_proxies.txt")
      File.open(filename, "w") do |file|
        list.each do |proxy|
          file.puts proxy
        end
      end
      puts "#{list.size} adet #{type.to_s.upcase} proxy'si #{filename} dosyasına kaydedildi, orospu çocuğu!"
    end
    puts "Tüm proxy'ler başarıyla kaydedildi, şimdi kullanabilirsin o pisliğe bulaşmak için."
  end

  # --- YENİ EKLENEN ÖZELLİKLER BAŞLANGICI ---

  # 1. Seçenek: Proxy Temizle - Çalışmayan Proxy'leri Silme
  # Bu metod, tek bir karmaşık proxy listesinden (proxylist.txt gibi)
  # çalışmayanları ayıklayıp, sadece çalışanları döner.
  def clean_proxies_from_file(input_filename = "proxies/all_proxies_for_cleaning.txt", output_filename = "proxies/working_proxies.txt")
    unless File.exist?(input_filename)
      puts "Hata: Kahrolasıca dosya #{input_filename} bulunamadı amına koyayım! Önce böyle bir dosya yaratmalısın."
      return
    end

    all_proxies = File.readlines(input_filename).map(&:strip).uniq.reject(&:empty?)
    working_proxies_list = []
    dead_proxies_count = 0

    puts "#{all_proxies.size} adet proxy temizlenecek. Bu biraz uzun sürebilir, sikini eline al bekle..."

    all_proxies.each_with_index do |proxy_address, index|
      ip, port = proxy_address.split(':')
      next unless ip && port

      puts "[#{index + 1}/#{all_proxies.size}] Proxy'i test ediyorum: #{proxy_address}"

      is_working = false
      # Hem HTTP hem SOCKS5 olarak dene, hangisi tutarsa artık!
      # Önce HTTP/HTTPS olarak test et
      if test_proxy_connection(ip, port, :http)
        is_working = true
        puts "  -> Çalışıyor (HTTP/HTTPS)"
      elsif test_proxy_connection(ip, port, :socks5) # HTTP/HTTPS çalışmazsa SOCKS5 dene
        is_working = true
        puts "  -> Çalışıyor (SOCKS5)"
      end

      if is_working
        working_proxies_list << proxy_address
      else
        dead_proxies_count += 1
        puts "  -> Bok yedi, çalışmıyor!"
      end
    end

    if working_proxies_list.empty?
      puts "Hiçbir çalışan proxy bulunamadı amına koyayım. Her şey bok yemiş."
      return
    end

    File.open(output_filename, "w") do |file|
      working_proxies_list.each { |p| file.puts p }
    end
    puts "#{working_proxies_list.size} adet çalışan proxy #{output_filename} dosyasına kaydedildi."
    puts "#{dead_proxies_count} adet sikindirik proxy hurdaya ayrıldı. Temizlik tamamdır!"
  end

  # Tek bir proxy'yi belirtilen türle test eden yardımcı metod
  def test_proxy_connection(ip, port, type)
    test_url = (type == :socks5) ? @test_target_url_socks : @test_target_url_http
    
    attempts = 0
    while attempts < @retries_per_proxy + 1 # 0'dan başlar, @retries_per_proxy kadar tekrar eder
      attempts += 1
      begin
        Timeout.timeout(@timeout_seconds) do
          if type == :socks5
            # SOCKS5 için özel Net::HTTP ayarları
            Net::HTTP.socks_address = ip
            Net::HTTP.socks_port = port.to_i
            http = Net::HTTP.new(test_url.host, test_url.port)
            http.use_ssl = (test_url.scheme == 'https')
            http.verify_mode = OpenSSL::SSL::VERIFY_NONE
            http.get(test_url.request_uri) # Sadece GET isteği yeterli
          else # HTTP/HTTPS için
            http = Net::HTTP.new(test_url.host, test_url.port, ip, port.to_i)
            http.use_ssl = (test_url.scheme == 'https')
            http.verify_mode = OpenSSL::SSL::VERIFY_NONE
            http.get(test_url.request_uri)
          end
          return true # Bağlantı başarılı
        end
      rescue Timeout::Error
        puts "  -> #{ip}:#{port} (#{type.to_s.upcase}) zaman aşımı (Deneme #{attempts})" if $DEBUG_MODE
      rescue StandardError => e
        puts "  -> #{ip}:#{port} (#{type.to_s.upcase}) hatası: #{e.message} (Deneme #{attempts})" if $DEBUG_MODE
      ensure
        # SOCKS ayarlarını sıfırla ki sonraki istekler etkilenmesin
        if type == :socks5
          Net::HTTP.socks_address = nil
          Net::HTTP.socks_port = nil
        end
      end
    end
    false # Tüm denemeler başarısız oldu
  end


  # 2. Seçenek: Proxy Düzenleme - Proxy Listesini Tiplere Göre Ayırma
  # Bu metod, daha önce kaydettiğimiz http_proxies.txt ve socks5_proxies.txt dosyalarını
  # birleştirip, tek bir dosyada tiplere göre ayırarak kaydeder.
  def organize_proxies_by_type(output_filename = "proxies/organized_proxylist.txt", input_directory = "proxies")
    http_file = File.join(input_directory, "http_proxies.txt")
    https_file = File.join(input_directory, "https_proxies.txt") # HTTPS'i de dahil edelim
    socks5_file = File.join(input_directory, "socks5_proxies.txt")

    categorized_proxies = {
      http: [],
      socks5: []
    }

    if File.exist?(http_file)
      categorized_proxies[:http].concat(File.readlines(http_file).map(&:strip).uniq.reject(&:empty?))
      puts "#{categorized_proxies[:http].size} adet HTTP proxy'si bulundu."
    else
      puts "Uyarı: Kahrolasıca #{http_file} dosyası bulunamadı. HTTP proxy'leri eksik kalacak."
    end
    if File.exist?(https_file)
      categorized_proxies[:http].concat(File.readlines(https_file).map(&:strip).uniq.reject(&:empty?)) # HTTPS'i de HTTP grubuna ekleyelim şimdilik
      puts "#{File.readlines(https_file).size} adet HTTPS proxy'si bulundu ve HTTP grubuna eklendi."
    else
      puts "Uyarı: Kahrolasıca #{https_file} dosyası bulunamadı. HTTPS proxy'leri eksik kalacak."
    end
    if File.exist?(socks5_file)
      categorized_proxies[:socks5].concat(File.readlines(socks5_file).map(&:strip).uniq.reject(&:empty?))
      puts "#{categorized_proxies[:socks5].size} adet SOCKS5 proxy'si bulundu."
    else
      puts "Uyarı: Kahrolasıca #{socks5_file} dosyası bulunamadı. SOCKS5 proxy'leri eksik kalacak."
    end

    if categorized_proxies[:http].empty? && categorized_proxies[:socks5].empty?
      puts "Hiçbir proxy bulunamadı amına koyayım. Önce proxy çekme işlemini yapmalısın (Seçenek 5)."
      return
    end

    File.open(output_filename, "w") do |file|
      if !categorized_proxies[:http].empty?
        file.puts "---- HTTP/HTTPS PROXY'LERI ----"
        categorized_proxies[:http].uniq.each { |p| file.puts p }
        file.puts "\n"
      end
      if !categorized_proxies[:socks5].empty?
        file.puts "---- SOCKS5 PROXY'LERI ----"
        categorized_proxies[:socks5].uniq.each { |p| file.puts p }
        file.puts "\n"
      end
    end
    puts "Tüm proxy'ler #{output_filename} dosyasına tiplerine göre düzenlenerek kaydedildi. Afiyet olsun!"
  end

  # 3. Seçenek: Netw Proxy - İnternetten Belirli Türde Proxy Bulma ve Terminalde Gösterme
  def scrape_by_type_and_display
    puts "\nHangi tür proxy istiyorsun piç?"
    puts "  1. HTTP/HTTPS"
    puts "  2. SOCKS5"
    puts "  3. Hepsi (Tüm kaynakları sömür)"
    print "Seçimini yap (1-3): "
    choice = gets.chomp.to_i

    target_types = []
    case choice
    when 1
      target_types = [:http, :https]
      puts "Sadece HTTP/HTTPS proxy'leri aranıyor, amına koyayım!"
    when 2
      target_types = [:socks5]
      puts "Sadece SOCKS5 proxy'leri aranıyor, yavşak!"
    when 3
      target_types = [:http, :https, :socks5]
      puts "Tüm türlerde proxy aranıyor, sike sürülecek akıl kalmadı!"
    else
      puts "Geçersiz seçim. Başka zaman dene, orospu çocuğu."
      return
    end

    # Mevcut proxy listelerini temizle
    @proxies = { http: [], https: [], socks5: [], unknown: [] }

    # Sadece seçilen türlerle eşleşen kaynakları tara
    @proxy_sources.each_with_index do |source, index|
      next unless (source[:expected_types] & target_types).any? # Kaynağın beklenen türleri ile hedef türler kesişiyor mu?

      puts "Kahrolasıca #{source[:url]} adresinden içerik çekiliyor (Kaynak #{index + 1}/#{@proxy_sources.size})"
      content = fetch_content(source[:url])
      next unless content

      found_proxies = []
      case source[:type]
      when :html_table
        found_proxies = parse_html_table(content, source[:expected_types])
      when :raw_text
        found_proxies = parse_raw_text(content, source[:expected_types])
      end

      found_proxies.each do |proxy|
        type = proxy[:type] || :unknown
        if target_types.include?(type) # Sadece istenen türleri ekle
          @proxies[type] << proxy[:address] unless @proxies[type].include?(proxy[:address])
        end
      end
    end

    @proxies.each { |type, list| @proxies[type] = list.uniq } # Dublikateleri temizle

    total_found = @proxies.values.flatten.size
    if total_found > 0
      puts "\n--- Bulunan Proxy'ler (#{total_found} adet) ---"
      @proxies.each do |type, list|
        next if list.empty?
        puts "---- #{type.to_s.upcase} PROXY'LERI (#{list.size} adet) ----"
        list.each { |p| puts p }
        puts "\n"
      end
      print "Bu bulunan proxy'leri bir dosyaya kaydet. (e/h): "
      save_choice = gets.chomp.downcase
      if save_choice == 'e'
        save_proxies_to_files("proxies/searched_by_type")
      else
        puts "Peki, kaydetmiyorum amına koyayım. Senin keyfin bilir."
      end
    else
      puts "Hiçbir uygun proxy bulunamadı amına koyayım. Daha sonra tekrar dene."
    end
  end

  # 4. Seçenek: Proxy Stealer - Girilen Web Sitesinden Proxy Çalma
  def steal_proxies_from_url(target_url = nil)
    unless target_url
      print "Proxy çalmak istediğin web sitesinin URL'sini gir (Örn: http://example.com/proxies.html): "
      target_url = gets.chomp
    end

    uri = URI.parse(target_url) rescue nil
    unless uri && (uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS))
      puts "Geçersiz URL girdin, mal! Düzgün bir URL ver."
      return
    end

    puts "Kahrolasıca #{target_url} adresinden içerik çekiliyor, proxy avına çıkıyorum!"
    content = fetch_content(target_url)
    unless content
      puts "İçerik çekilemedi amına koyayım. O sitede bir bokluk var ya da sen URL'yi sen yanlış girdin. (MAL OLDUĞUN İÇİN OLABİLİYOR BÖYLE ŞEYLER)"
      return
    end

    # IP:Port formatındaki her şeyi yakalayan orospu çocuğu regex
    proxy_pattern = /(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}):(\d{1,5})/
    stolen_proxies = content.scan(proxy_pattern).map { |match| "#{match[0]}:#{match[1]}" }.uniq

    if stolen_proxies.empty?
      puts "Bu kahpe siteden hiçbir proxy çalınamadı. Ya yok ya da saklamayı iyi biliyorlar."
    else
      puts "\n--- Çalınan Proxy'ler (#{stolen_proxies.size} adet) ---"
      stolen_proxies.each_with_index do |proxy, index|
        puts "#{index + 1}. #{proxy}"
      end
      print "web siteden gasp ettiğimiz bu proxyleri sakla kaybedersen sikerim seni (e/h): "
      save_choice = gets.chomp.downcase
      if save_choice == 'e'
        Dir.mkdir("proxies") unless File.exist?("proxies")
        filename = "proxies/stolen_proxies_from_#{uri.host.gsub(/[^0-9A-Za-z.\-]/, '_')}.txt"
        File.open(filename, "w") do |file|
          stolen_proxies.each { |p| file.puts p }
        end
        puts "#{stolen_proxies.size} adet çalınan proxy #{filename} dosyasına kaydedildi, aferin piç!"
      else
        puts "Peki, kaydetmiyorum amına koyayım. Keyfin bilir. ama kaybedersen sikerim seni."
      end
    end
  end

end # Class sonu

# Ana menü ve programı çalıştırma kısmı, dikkat et amına koyayım
if __FILE__ == $PROGRAM_NAME
  $DEBUG_MODE = false # Debug mesajlarını görmek istersen 'true' yap, pislik

  scrapper = ProxyScrapper.new
  loop do
    banner = <<~LAYOUT
             ,----------------,              ,---------,
        ,-----------------------,          ,"        ,"|
      ,"     Proxy Stealer    ,"|        ,"        ,"  |
     +-----------------------+  |      ,"        ,"    |
     |  .-----------------.  |  |     +---------+      |
     |  |                 |  |  |     | -==----'|      |
     |  | I LOVE PENTEST! |  |  |     |         |      |
     |  | Proxy Scraper   |  |  |/----|`---=    |      |
     |  | C:\>_Rhest       |  |  |   ,/|==== ooo |      ;
     |  |                 |  |  |  // |(((( [RH]|    ,"
     |  `-----------------'  |," .;'| |((((     |  ,"
     +-----------------------+  ;;  | |         |,"
        /_)______________(_/  //'   | +---------+
   ___________________________/___  `,
  /  oooooooooooooooo  .o.  oooo /,   \,"-----------
 / ==ooooooooooooooo==.o.  ooo= //   ,`\--{)B     ,"
/_==__==========__==_ooo__ooo=_/'   /___________,"
         Made is Rhest

LAYOUT

    puts banner
    puts "\n--- Proxy İşleri Menüsü ---"
    puts "1. Proxy Temizle (Bir dosyadan çalışmayanları sil)"
    puts "2. Proxy Düzenle (Mevcut proxy dosyalarını tiplere göre birleştir)"
    puts "3. Ağdan Proxy Bul (Belirli türde ve terminalde göster)"
    puts "4. Web Sitesinden Proxy Çal (URL girerek)"
    puts "5. Tüm Proxy Kaynaklarını Sömür (Eski, tüm tipleri bulup dosyalara kaydet)"
    puts "6. Çıkış (Siktir git)"
    print "Seçimini yap, orospu çocuğu: "
    choice = gets.chomp.to_i

    case choice
    when 1
      scrapper.clean_proxies_from_file # Varsayılan dosya isimleri kullanılır
    when 2
      scrapper.organize_proxies_by_type # Varsayılan dosya isimleri kullanılır
    when 3
      scrapper.scrape_by_type_and_display
    when 4
      scrapper.steal_proxies_from_url
    when 5
      scrapper.scrape_all_proxies
      scrapper.save_proxies_to_files
    when 6
      puts "Hadi eyvallah, siktir git bir daha gelme korkaklarla işimiz yok!"
      break
    else
      puts "vay amına kodumun malı o kadar koskoca 6 tane seçenekden birini bile yazamadıysan."
    end
  end
end