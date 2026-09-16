# docker_maths/manifests/init.pp
class docker_maths (
  Array[String]   $docker_users     = [],
  Boolean         $enable_nvidia    = false,
  Optional[String] $data_root       = undef,
  Optional[String] $containerd_root = undef,
) {
  ensure_packages(['jq'])

  if $data_root {
    file { '/etc/docker':
      ensure => directory,
      before => Class['docker'],
    }

    file { '/etc/docker/daemon.json':
      ensure  => file,
      content => '{}',
      replace => false,
      require => File['/etc/docker'],
      before  => Class['docker'],
    }

    exec { 'docker_data_root':
      command => "/bin/sh -c 'jq \". + {\\\"data-root\\\": \\\"${data_root}\\\"}\" /etc/docker/daemon.json > /etc/docker/daemon.json.tmp && mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json'",
      unless  => "/usr/bin/jq -e '.\"data-root\" == \"${data_root}\"' /etc/docker/daemon.json",
      require => File['/etc/docker/daemon.json'],
      before  => Class['docker'],
      notify  => Service['docker'],
    }
  }

  if $containerd_root {
    file { '/etc/containerd':
      ensure => directory,
      before => Class['docker'],
    }

    file { '/etc/containerd/config.toml':
      ensure  => file,
      content => "version = 2\nroot = \"${containerd_root}\"\n",
      require => File['/etc/containerd'],
      before  => Class['docker'],
    }

    service { 'containerd':
      ensure    => running,
      enable    => true,
      subscribe => File['/etc/containerd/config.toml'],
    }
  }

  class { 'docker':
    docker_users                => $docker_users,
    use_upstream_package_source => false,
    docker_ce_package_name      => 'docker.io',
  }
  contain 'docker'

  # Daily cleanup, matching the manual routine already in use — prevents
  # unbounded growth from stopped containers and unused images even once
  # storage is redirected off the small root filesystem.
  file { '/etc/cron.daily/docker-clean':
    ensure  => file,
    mode    => '0755',
    require => Class['docker'],
    content => @(SCRIPT)
      #!/bin/sh
      docker container prune -f > /dev/null 2>/tmp/docker-cleanup.err
      docker image prune -a -f > /dev/null 2>>/tmp/docker-cleanup.err

      if [ -s /tmp/docker-cleanup.err ]; then
          cat /tmp/docker-cleanup.err
      fi
      | SCRIPT
  }

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
