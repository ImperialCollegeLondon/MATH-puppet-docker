# docker_maths/manifests/init.pp
class docker_maths (
  Array[String] $docker_users  = [],
  Boolean       $enable_nvidia = false,
) {
  class { 'docker':
    docker_users => $docker_users,
    use_upstream_package_source => false,
    package_name                => 'docker.io',
  }
  contain 'docker'

  if $enable_nvidia {
    # ensure_packages, not a plain package declaration: github_actions_runner_maths
    # also needs curl, and both modules are meant to coexist on the same
    # node — a plain `package { 'curl': }` in both would be a
    # duplicate-declaration error.
    ensure_packages(['curl', 'gnupg', 'ca-certificates', 'jq'])

    exec { 'nvidia_container_toolkit_gpg_key':
      command => '/usr/bin/curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | /usr/bin/gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg',
      creates => '/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg',
      path    => ['/usr/bin', '/bin'],
      require => [Package['curl'], Package['gnupg']],
      # Deliberately does not require Class['docker']: `contain 'docker'`
      # above means Class['docker'] includes Service['docker'], and
      # nvidia_ctk_configure_docker below notifies that same service —
      # requiring the whole class here would create an unsatisfiable
      # ordering cycle. Docker installing first relies on manifest order
      # (class { 'docker': } is declared above this block), not an
      # explicit graph edge.
    }

    file { '/etc/apt/sources.list.d/nvidia-container-toolkit.list':
      ensure  => file,
      content => "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/\$(ARCH) /\n",
      require => [Exec['nvidia_container_toolkit_gpg_key'], Package['ca-certificates']],
      notify  => Exec['apt_update_nvidia'],
    }

    # State-checked, not just notify-triggered: a failed apt-get update
    # would otherwise never get retried, since the .list file's content
    # doesn't change again to re-trigger the notify on a later run.
    exec { 'apt_update_nvidia':
      command => '/usr/bin/apt-get update',
      unless  => '/usr/bin/apt-cache show nvidia-container-toolkit',
      require => File['/etc/apt/sources.list.d/nvidia-container-toolkit.list'],
    }

    package { 'nvidia-container-toolkit':
      ensure  => installed,
      require => [File['/etc/apt/sources.list.d/nvidia-container-toolkit.list'], Exec['apt_update_nvidia']],
    }

    # Checks the actual JSON structure nvidia-ctk writes (runtimes.nvidia)
    # rather than a plain substring match, which could false-positive
    # against unrelated text elsewhere in the file.
    exec { 'nvidia_ctk_configure_docker':
      command => '/usr/bin/nvidia-ctk runtime configure --runtime=docker',
      unless  => '/usr/bin/jq -e ".runtimes.nvidia" /etc/docker/daemon.json',
      require => [Package['nvidia-container-toolkit'], Package['jq']],
      notify  => Service['docker'],
    }
  }
}
