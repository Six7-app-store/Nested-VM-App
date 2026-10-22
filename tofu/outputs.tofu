
############################
# [CONTRACT] User Accounts Output
############################

# protocol nach ADR 0007 im deployment-Repo: type sagt, was auth ist
# (ein Passwort), protocol, wie man die VM erreicht (SSH).
output "user_accounts" {
  description = "[CONTRACT] User accounts mit Login-Informationen"
  sensitive   = true # Enthält Passwörter
  value = {
    for id, user in local.users_map : id => {
      type     = "password"
      protocol = "ssh"
      ip       = local.access_ip[id]
      port     = 22
      username = user.username
      auth     = random_password.user_passwords[id].result
      email    = user.email
      team     = user.team
    }
  }
}

############################
# VM Details
############################

output "team_vms" {
  description = "Details der VMs, eine je Person"
  value = {
    for id, user in local.users_map : id => {
      instance_id           = openstack_compute_instance_v2.user_vm[id].id
      instance_name         = openstack_compute_instance_v2.user_vm[id].name
      ip_mode               = var.ip_mode
      fixed_ip_v4           = local.ipv4_address[id]
      fixed_ip_v6           = local.ipv6_address[id]
      username              = user.username
      team                  = user.team
      nested_virtualization = var.nested_virtualization
      ssh_command           = "ssh ${user.username}@${local.access_ip[id]}"
    }
  }
}

output "teams_summary" {
  description = "Übersicht: Anzahl VMs und User"
  value = {
    vm_count   = local.vm_count
    user_count = length(local.all_users)
    usernames  = local.usernames
    emails     = local.emails
    teams      = local.unique_teams
  }
}
