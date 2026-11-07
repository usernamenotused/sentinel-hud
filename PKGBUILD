# Maintainer: Brandon Nelson <nelson.brandons@gmail.com>
pkgname=sentinel-hud-git
_pkgname=sentinel-hud
pkgver=1.0.0
pkgrel=1
pkgdesc="Live system, network and security HUD drawn on the Wayland desktop (Quickshell)"
arch=('any')
url="https://github.com/usernamenotused/sentinel-hud"
license=('MIT')
depends=('quickshell' 'jq' 'iproute2' 'systemd' 'bash' 'pacman-contrib' 'hwdata')
makedepends=('git')
optdepends=(
  'arch-audit: security advisory count'
  'networkmanager: Wi-Fi SSID readout'
  'ufw: firewall status and block log'
  'nmap: faster opt-in LAN sweep'
  'avahi: mDNS names on the network map'
  'git: REPOS panel'
  'ttf-jetbrains-mono-nerd: intended font'
)
provides=("$_pkgname")
conflicts=("$_pkgname")
source=("$_pkgname::git+$url.git")
sha256sums=('SKIP')

pkgver() {
  cd "$_pkgname"
  printf "r%s.%s" "$(git rev-list --count HEAD)" "$(git rev-parse --short=7 HEAD)"
}

package() {
  cd "$_pkgname"
  local share="$pkgdir/usr/share/$_pkgname"
  install -Dm644 -t "$share" shell.qml Hud.qml NetMap.qml config.example sweep-networks.example
  install -Dm755 -t "$share" hud.sh netmap.sh
  install -Dm755 sentinel-hud "$pkgdir/usr/bin/sentinel-hud"
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
}
