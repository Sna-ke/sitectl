# shellcheck shell=bash
#
# sitectl library: sitectl list.
# Sourced by /usr/local/sbin/sitectl; not meant to be run on its own.
#
# Everything here is read from the server itself (the nginx configs,
# certbot's files, group membership), not from a separate database, so
# it's always right, even after a config is edited by hand.

# Print one site's details as tab-separated fields:
#   domain user type www cert-expiry <one per module column> web-folder
# Module columns come from enabled modules with a site_info function
# (e.g. sftp: yes/no), in LIST_MODULES order.
site_details() {
  local config="$1"
  local domain="${config##*/}"
  local user root type www expiry cert module value module_values=""

  user=$(site_user_from_config "$config")
  root=$(sed -n 's/^[[:space:]]*root[[:space:]]\{1,\}\([^;]*\);.*/\1/p' "$config" | head -n 1)

  type="static"
  grep -q "fastcgi_pass" "$config" && type="php"

  www="no"
  grep -m 1 "server_name" "$config" | grep -qF " www.$domain" && www="yes"

  # The certificate's expiry date. certbot keeps certificates in folders
  # only root can open, so without sudo there's no way to tell whether one
  # exists: say so, rather than wrongly reporting "none".
  expiry="none"
  cert="/etc/letsencrypt/live/$domain/cert.pem"
  if [[ -d /etc/letsencrypt/live && ! -x /etc/letsencrypt/live ]] ||
     [[ -e "/etc/letsencrypt/live/$domain" && ! -r "$cert" ]]; then
    expiry="(needs sudo)"
  elif [[ -r "$cert" ]]; then
    expiry=$(date -d "$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2)" +%Y-%m-%d 2> /dev/null || echo "?")
    if [[ -f "$RENEWAL_DIR/$domain.conf$PAUSED_SUFFIX" ]]; then
      expiry+=" (renewal paused)"
    fi
  fi

  for module in $LIST_MODULES; do
    value=$("module_${module}_site_info" "$domain" "$user" 2> /dev/null || true)
    module_values+="${value:--}"$'\t'
  done

  printf '%s\t%s\t%s\t%s\t%s\t%s%s\n' "$domain" "$user" "$type" "$www" "$expiry" "$module_values" "$root"
}

# Sort key that puts subdomains straight after their main domain:
# demo.example.com -> com.example.demo
reversed_name() {
  local IFS="." part parts reversed=""
  read -r -a parts <<< "$1"
  for (( part = ${#parts[@]} - 1; part >= 0; part-- )); do
    reversed+="${parts[$part]}."
  done
  echo "${reversed%.}"
}

# Escape a value for JSON. Domains, usernames and paths here only contain
# plain characters, but escape quotes and backslashes to be safe.
json_string() {
  local value="${1//\\/\\\\}"
  printf '"%s"' "${value//\"/\\\"}"
}

# sitectl list [DOMAIN] [--json]
#   No DOMAIN: every site. With DOMAIN: that site and its subdomains.
cmd_list() {
  local filter="${1:-}" format="${LIST_FORMAT:-table}"
  local config domain lines=() sorted
  LIST_MODULES=$(modules_with_site_info | tr '\n' ' ')

  while read -r config; do
    [[ -n "$config" ]] || continue
    domain="${config##*/}"
    if [[ -n "$filter" && "$domain" != "$filter" && "$domain" != *".$filter" ]]; then
      continue
    fi
    lines+=("$(reversed_name "$domain")"$'\t'"$(site_details "$config")")
  done < <(site_config_files)

  if (( ${#lines[@]} == 0 )); then
    if [[ "$format" == "json" ]]; then
      echo "[]"
    elif [[ -n "$filter" ]]; then
      echo "No site called $filter (or subdomains of it) is managed by sitectl here."
    else
      echo "No sites are managed by sitectl here yet. Add one with: sudo sitectl add example.com"
    fi
    return
  fi

  sorted=$(printf '%s\n' "${lines[@]}" | sort | cut -f2-)

  local fields module i
  if [[ "$format" == "json" ]]; then
    local first="yes" modules_json
    echo "["
    while IFS=$'\t' read -r -a fields; do
      [[ "$first" == "yes" ]] || echo ","
      first="no"
      # fields: domain user type www expiry <modules...> root
      modules_json="" i=5
      for module in $LIST_MODULES; do
        modules_json+="${modules_json:+, }$(json_string "$module"): $(json_string "${fields[$i]}")"
        i=$((i + 1))
      done
      printf '  {"domain": %s, "user": %s, "type": %s, "www": %s, "certificate_checked": %s, "certificate_expires": %s, "web_folder": %s, "modules": {%s}}' \
        "$(json_string "${fields[0]}")" "$(json_string "${fields[1]}")" "$(json_string "${fields[2]}")" \
        "$([[ "${fields[3]}" == "yes" ]] && echo true || echo false)" \
        "$([[ "${fields[4]}" == "(needs sudo)" ]] && echo false || echo true)" \
        "$(if [[ "${fields[4]}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then json_string "${fields[4]:0:10}"; else echo null; fi)" \
        "$(json_string "${fields[-1]}")" "$modules_json"
    done <<< "$sorted"
    echo
    echo "]"
    return
  fi

  # Table: subdomains are indented under the site they belong to.
  local all_domains
  all_domains=$(cut -f1 <<< "$sorted")
  {
    printf 'DOMAIN\tUSER\tTYPE\tWWW\tCERTIFICATE\t'
    for module in $LIST_MODULES; do printf '%s\t' "${module^^}"; done
    printf 'WEB FOLDER\n'
    while IFS=$'\t' read -r -a fields; do
      local indent="" other
      while read -r other; do
        if [[ "${fields[0]}" == *".$other" ]]; then
          indent+="  "
        fi
      done <<< "$all_domains"
      fields[0]="$indent${fields[0]}"
      (IFS=$'\t'; echo "${fields[*]}")
    done <<< "$sorted"
  } | align_columns

  if [[ -d /etc/letsencrypt/live && ! -x /etc/letsencrypt/live ]]; then
    echo
    echo "Certificate details are only visible to root: run 'sudo sitectl list' to see them."
  fi
}

# Line up tab-separated columns (like `column -t`, which isn't on every
# Ubuntu install). Leading spaces, used to indent subdomains, are kept.
align_columns() {
  awk -F'\t' '
    { rows[NR] = $0; for (i = 1; i <= NF; i++) if (length($i) > w[i]) w[i] = length($i); n = (NF > n ? NF : n) }
    END {
      for (r = 1; r <= NR; r++) {
        split(rows[r], f, "\t"); line = ""
        for (i = 1; i <= n; i++) line = line sprintf(i < n ? "%-" w[i] + 2 "s" : "%s", f[i])
        sub(/ +$/, "", line); print line
      }
    }'
}
