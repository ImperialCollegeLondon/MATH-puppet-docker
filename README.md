# docker_maths

Docker Engine installation for Imperial Maths department servers,
wrapping `puppetlabs/docker` with department defaults.

## Usage

    class { 'docker_maths':
      docker_users  => ['github-runner'],
      enable_nvidia => true,
    }

## Parameters

- `docker_users` (default `[]`) — usernames to add to the `docker`
  group, via `puppetlabs/docker`'s own `docker_users` mechanism. If a
  user is already managed as a resource by another class (e.g. a
  runner user created elsewhere), prefer amending its `groups` via a
  resource collector at the composing/profile layer instead, to avoid
  routing group membership through two different mechanisms for the
  same user.
- `enable_nvidia` (default `false`) — installs and configures
  `nvidia-container-toolkit` so Docker containers can request GPU
  access (`docker run --gpus all`).

## NVIDIA notes

- The NVIDIA GPU driver itself must already be installed on the host —
  this module only wires up the *container* toolkit, not the driver.
- Setting `enable_nvidia => false` does **not** remove a previously
  installed toolkit or undo `nvidia-ctk`'s changes to
  `/etc/docker/daemon.json` — it simply stops managing that
  configuration going forward.
- `nvidia-ctk runtime configure` edits `/etc/docker/daemon.json`
  directly. If you ever pass `docker_maths` parameters that cause
  `puppetlabs/docker` to also manage `daemon.json`'s content, the two
  mechanisms would compete for ownership of the same file. As currently
  used (only `docker_users` is set), `puppetlabs/docker` doesn't
  generate `daemon.json` content, so this isn't an active conflict —
  worth revisiting if that changes.
