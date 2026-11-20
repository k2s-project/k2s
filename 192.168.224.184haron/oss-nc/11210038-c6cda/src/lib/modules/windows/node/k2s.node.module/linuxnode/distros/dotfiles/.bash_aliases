# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0
# common aliases
alias l='ls -F'
alias la='ls -F -a'
alias ls='ls --color=auto -F'
alias ll='ls -lF'

# kubernetes stuff
alias k='kubectl'

alias kg='kubectl get'
alias kgp='kubectl get pods -A'
alias kgetall='kubectl get --all-namespaces all'
alias kgsvc='kubectl get service -A'
alias kgss='kubectl get statefulset -A'
alias kgdep='kubectl get deployments -A'

alias kd='kubectl describe'
alias kdp='kubectl describe pod'

alias ka='kubectl apply'
alias kaf='kubectl apply -f'

alias ke='kubectl get -o yaml'

alias kuc='kubectl config use-context'
alias kgc='kubectl config get-contexts'

alias kl='kubectl logs'
alias kei='kubectl exec -it'

alias d='sudo docker'
alias dsp='sudo docker system prune -f'

alias cdb='cd ~/bin'
alias cdt='cd /mnt/k8s-smb-share/transfer'

alias xx=exit
alias m=less
alias e=vim
alias v=vim
alias n=nano
alias rmt='/bin/rm -fr'
alias h='history  | tail -39'

#PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
PS1='${debian_chroot:+($debian_chroot)}\h:\w\$ '
unset color_prompt force_color_prompt

# completions for K8s and Docker
. ~/.bash_kubectl
. ~/.bash_docker



