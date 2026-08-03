[ -e /etc/profile ] && source /etc/profile

# Désactive la traduction française pour les messages du système
unset LANG LC_MESSAGES
export LC_ALL="en_US.UTF-8"
export LC_CTYPE="$LC_ALL"
export LESSCHARSET="utf-8"
export TIME_STYLE="long-iso"
export TZ="Europe/Paris"
export PERL_UTF8_LOCALE=1 PERL_UNICODE=AS
export LC_MEASUREMENT="fr_FR.UTF-8"
export LC_PAPER="fr_FR.UTF-8"
export LC_MONETARY="fr_FR.UTF-8"

MYPATH=/opt/emacs/bin/:${JAVA_HOME}/bin:${HOME}/bin:${HOME}/.local/bin:${HOME}/bin/go:${HOME}/.nix-profile/bin

export NODE_DISABLE_COLORS=1
export NODE_OPTIONS="--max_old_space_size=8096"
export GOBIN=/home/pi/bin/go/

# Rust completion
[ -e "$HOME/.cargo/env" ] && {
    source "$HOME/.cargo/env"
    MYPATH="$MYPATH:$HOME/.cargo/bin"
}

[ -e "$HOME/.config/composer/vendor/bin/" ] && MYPATH="$MYPATH:$HOME/.config/composer/vendor/bin"
[ -e "/nix/var/nix/profiles/default/bin/" ] && MYPATH="$MYPATH:/nix/var/nix/profiles/default/bin"
[ -e "$HOME/node_modules/.bin/" ] && MYPATH="$MYPATH:$HOME/node_modules/.bin"

export NVM_DIR="$HOME/.config/nvm"

# Never use `export PATH="$PATH:/x/y/z/"` because recursive launching will increase the value
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games:$GOBIN:$MYPATH"
export GITNEXUS_LBUG_EXTENSION_INSTALL=auto

type mise &>/dev/null && [ -e "$HOME/.config/mise/shell-init.sh" ] && source "$HOME/.config/mise/shell-init.sh"
