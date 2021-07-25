Gem::Specification.new do |spec|
  spec.name        = 'muzik'
  spec.version     = '0.1.0'
  spec.licenses    = ['MIT']
  spec.summary     = 'Personal music manager'
  spec.description = 'Muzik manages your personal library of music files by syncing it across your devices using Google Drive.'
  spec.authors     = ['Thomas Russoniello']
  spec.email       = 'tommy.russoniello@gmail.com'
  spec.files       = Dir['LICENSE.txt', 'README.md', 'bin/**/*', 'lib/**/*']
  spec.homepage    = 'https://github.com/tommy-russoniello/muzik'
  spec.metadata    = { 'source_code_uri' => 'https://github.com/tommy-russoniello/muzik' }
  spec.executables << 'muzik'
end
