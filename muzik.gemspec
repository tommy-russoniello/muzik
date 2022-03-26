Gem::Specification.new do |spec|
  spec.name        = 'muzik'
  spec.version     = '0.3.0'
  spec.licenses    = ['MIT']
  spec.summary     = 'Personal music manager'
  spec.description = 'Muzik manages your personal library of music files by syncing it across your devices using Google Drive.'
  spec.authors     = ['Thomas Russoniello']
  spec.email       = 'tommy.russoniello@gmail.com'
  spec.files       = Dir['LICENSE.txt', 'README.md', 'bin/**/*', 'lib/**/*']
  spec.homepage    = 'https://github.com/tommy-russoniello/muzik'
  spec.metadata    = { 'source_code_uri' => 'https://github.com/tommy-russoniello/muzik' }
  spec.executables << 'muzik'

  spec.required_ruby_version = '>= 2.7'

  spec.add_dependency 'octokit', '~> 4.20'
  spec.add_dependency 'google_drive', '~> 3.0'
  spec.add_dependency 'id3tag', '~> 0.14'
  spec.add_dependency 'colorize', '~> 0.8'
  spec.add_dependency 'rb-scpt', '~> 1.0'
end
