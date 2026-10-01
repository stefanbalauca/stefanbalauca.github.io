# Run after `bundle exec jekyll build`: bundle exec ruby test/integration_publications.rb
require "bibtex"
require "nokogiri"
require "set"
require "uri"
require "yaml"

root = File.expand_path("..", __dir__)
destination = File.expand_path(ARGV.fetch(0, "_site"), root)
config = YAML.load_file(File.join(root, "_config.yml"))
entries = BibTeX.open(File.join(root, "_bibliography/papers.bib")).entries.values
overview = Nokogiri::HTML(File.read(File.join(destination, "publications/index.html")))
filtered = config.fetch("filtered_bibtex_keywords").map(&:downcase)

def check(condition, message)
  abort message unless condition
end

entries.each do |entry|
  path = "/publications/#{entry.key}/"
  check(overview.at_css(".title a[href='#{path}']"), "Missing title link: #{path}")
  card = overview.at_css("[id='#{entry.key}']")
  check(card.at_css("a.bibtex"), "Missing Bib button: #{entry.key}")
  detail = Nokogiri::HTML(File.read(File.join(destination, path, "index.html")))
  check(!detail.at_css("h1").text.strip.empty?, "Missing detail title: #{entry.key}")
  check(detail.css(".author").text.include?("Stefan"), "Missing detail authors: #{entry.key}")
  check(detail.css(".periodical").text.include?(entry.year.to_s), "Missing year: #{entry.key}")
  check(detail.at_css("h2").text == "Abstract", "Missing abstract: #{entry.key}") if entry[:abstract]

  [card.at_css("div.bibtex pre"), detail.at_css("details pre")].each do |block|
    check(block, "Missing generated BibTeX: #{entry.key}")
    citation = BibTeX.parse(block.text).entries.values.fetch(0)
    check(citation.key == entry.key, "Changed citation key: #{entry.key}")
    check(citation.type == entry.type, "Changed citation type: #{entry.key}")
    fields = citation.fields.keys.map(&:to_s)
    check((fields & filtered).empty?, "Website metadata leaked: #{entry.key}")
    check(fields.sort == (entry.fields.keys.map(&:to_s) - filtered).sort, "Citation metadata lost: #{entry.key}")
  end

  %w[pdf doi arxiv code slides poster video website url].each do |resource|
    next unless entry[resource.to_sym]
    check(detail.at_css(".links a[href*='#{entry[resource.to_sym]}']"), "Missing #{resource}: #{entry.key}")
  end
end

expected = %w[/ /cv/ /publications/ /teaching/ /news/]
expected += entries.map { |entry| "/publications/#{entry.key}/" }
expected += Dir.glob(File.join(root, "_news/*.md")).map { |file| "/news/#{File.basename(file, '.md')}/" }
sitemap = Nokogiri::XML(File.read(File.join(destination, "sitemap.xml")))
actual = sitemap.remove_namespaces!.css("loc").map(&:text)
check(actual.to_set == expected.map { |path| config.fetch("url") + path }.to_set, "Sitemap differs from real site content")

broken = []
Dir.glob(File.join(destination, "**/*.html")).reject { |file| file.include?("/assets/") }.each do |file|
  document = Nokogiri::HTML(File.read(file))
  check(!document.css("meta[name='robots']").any? { |meta| meta["content"].include?("noindex") }, "Unexpected noindex: #{file}")
  document.css("a[href], img[src], script[src], link[href]").each do |node|
    target = node["href"] || node["src"]
    next if target.nil? || target.empty? || target.start_with?("#", "//")
    next if target.match?(/\A(?:data|mailto|tel|javascript):/i)
    uri = URI.parse(target)
    next if uri.scheme && !(uri.scheme == "https" && uri.host == URI(config.fetch("url")).host)
    path = URI::DEFAULT_PARSER.unescape(uri.path)
    local = path.start_with?("/") ? File.join(destination, path) : File.expand_path(path, File.dirname(file))
    local = File.join(local, "index.html") if File.directory?(local)
    broken << "#{file.delete_prefix(destination)} → #{target}" unless File.file?(local)
  end
end
check(broken.empty?, "Broken internal links:\n#{broken.uniq.join("\n")}")
%w[blog books projects teachings people plugins repositories bibliography].each do |demo|
  check(!File.exist?(File.join(destination, demo)), "Demo output remains: #{demo}")
end
puts "PASS: #{entries.length} publication pages, clean BibTeX, #{actual.length} sitemap URLs, and all internal page/asset links."
