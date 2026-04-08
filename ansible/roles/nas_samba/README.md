# nas_samba

Ansible role for managing Samba (SMB/CIFS) on Rocky Linux NAS nodes with
Pacemaker/PCS high-availability support.

Designed for active/passive HA clusters where PCS manages Samba lifecycle
alongside ZFS and VIP resources using explicit colocation and ordering
constraints (not resource groups).

## Variables

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `nas_samba_packages` | `[samba, samba-common]` | Packages to install |
| `nas_samba_min_protocol` | `SMB3` | Minimum SMB protocol version |
| `nas_samba_max_protocol` | `SMB3_11` | Maximum SMB protocol version |
| `nas_samba_encrypt` | `required` | SMB encryption setting |
| `nas_samba_server_signing` | `mandatory` | Server message signing |
| `nas_samba_client_signing` | `mandatory` | Client message signing |
| `nas_samba_disable_netbios` | `true` | Disable legacy NetBIOS |
| `nas_samba_workgroup` | `HOMELAB` | Workgroup name |
| `nas_samba_shares` | `[]` | List of share definitions (see below) |
| `nas_samba_users` | `[]` | List of Samba users (passwords from vault) |
| `nas_samba_pcs_enabled` | `true` | Whether PCS manages Samba |
| `nas_samba_pcs_resource_name` | `smb-service` | PCS resource name |
| `nas_samba_pcs_colocation_with` | `nas-vip` | Resource to colocate with |
| `nas_samba_pcs_order_after` | `nas-vip` | Resource that must start first |
| `nas_samba_pcs_monitor_interval` | `30s` | PCS health check interval |
| `nas_samba_pcs_start_timeout` | `30s` | PCS start timeout |
| `nas_samba_pcs_stop_timeout` | `30s` | PCS stop timeout |

## Share definition

```yaml
nas_samba_shares:
  - name: media
    path: /tank/media
    valid_users: "@media"
    writable: true
    browseable: true
    create_mask: "0664"
    directory_mask: "0775"
```

## User definition

Passwords **must** come from Ansible Vault variables:

```yaml
nas_samba_users:
  - name: editor
    password: "{{ vault_samba_editor_password }}"
```

## Example playbook

```yaml
- hosts: nas
  become: true
  roles:
    - role: nas_samba
      vars:
        nas_samba_shares:
          - name: media
            path: /tank/media
            valid_users: "@media"
            writable: true
        nas_samba_users:
          - name: editor
            password: "{{ vault_samba_editor_password }}"
        nas_samba_pcs_colocation_with: nas-vip
        nas_samba_pcs_order_after: nas-vip
```

## PCS constraints

This role creates **individual colocation and ordering constraints** rather
than resource groups. This avoids the cascading-restart bug in multi-protocol
PCS setups (iSCSI + NFS + SMB) and gives fine-grained failover control.

When `nas_samba_pcs_enabled` is true, the systemd `smb` service is disabled —
PCS is the sole owner of the Samba lifecycle.
