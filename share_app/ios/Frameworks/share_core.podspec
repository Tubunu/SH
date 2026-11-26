Pod::Spec.new do |s|
  s.name                = 'share_core'
  s.version             = '1.5.2'
  s.summary             = 'Rust native core framework for Share iOS.'
  s.description         = 'Cross-platform Rust core (crypto, HTTP client, SQLite store, WeSync codec) for Share.'
  s.homepage            = 'https://github.com'
  s.license             = { :type => 'MIT' }
  s.author              = { 'Share' => 'noreply@example.com' }
  s.source              = { :path => '.' }
  s.platform            = :ios, '15.0'
  s.vendored_frameworks = 'share_core.framework'
  s.frameworks          = 'Security', 'SystemConfiguration'
  s.libraries           = 'resolv'
end
