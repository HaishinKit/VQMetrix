require 'json'

module SiteLocalization
  MARKER = '<!-- vqmetrix-language -->'.freeze
  def self.install(output)
    files = Dir[File.join(output, '**/index.html')].select do |path|
      relative = path.delete_prefix(output + '/')
      relative == 'index.html' || relative == 'ja/index.html' || relative.start_with?('swift/', 'ja/swift/')
    end
    routes = files.map { |path| '/' + path.delete_prefix(output + '/').delete_suffix('index.html') }
    translated = routes.reject { |route| route.start_with?('/ja/') }.select { |route| routes.include?('/ja' + route) }
    script = File.read(File.join(__dir__, '../docs/site/language.js'))
      .sub('__VQ_TRANSLATED_ROUTES__', JSON.generate(translated))
    files.each do |path|
      html = File.read(path)
      html = html.sub(/<!-- vqmetrix-language -->.*?<!-- \/vqmetrix-language -->/m, '')
      lang = path.delete_prefix(output + '/').start_with?('ja/') ? 'ja' : 'en'
      html = html.sub(/<html\b([^>]*?)\blang="[^"]*"/, '<html\1lang="' + lang + '"')
      html = html.sub('</head>', "#{MARKER}<script>#{script}</script><!-- /vqmetrix-language --></head>")
      File.write(path, html)
    end
  end
end
