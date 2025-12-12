# os-wrapper
By default the `openstack` CLI re-authenticates on every single command.  
That means if you run a script that calls the CLI 20 times, it also hits Keystone 20 times.  
It’s slow, noisy, and generally pointless because Keystone tokens already have a TTL.

This wrapper just caches a token + expiry timestamp locally and reuses it until it’s about to expire.  
The CLI is then forced to use token auth instead of password auth, which avoids all the extra Keystone traffic.  
Basically: same CLI, same output, but without spamming Keystone for every command.

## What it does

- Loads your existing RC file (v3 only).
  - Alternatively, if `OS_*` credentials are already defined, uses those.
- Checks if a cached token exists and is still valid.
- If not valid, gets a new token once.
- Exports `OS_AUTH_TYPE=token` and `OS_TOKEN=<cached token>`.
- Runs the `openstack` CLI normally.
- That’s it.

It doesn’t touch your project scope or anything else from the RC file.

## Usage

1. Put `os.sh` somewhere in your `$PATH`.
   1. For example `sudo cp os.sh /usr/local/bin/os`
2. Make it executable:
   ```bash
   chmod +x os
   ```