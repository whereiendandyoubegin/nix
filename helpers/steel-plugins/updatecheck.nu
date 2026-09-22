const configfile = "../../home/shared/helixplugins.nix"

export def get-plugins []: string -> record {
  nix eval --json --file $in | from json
}

export def get-current []: record -> table {
  $in.interpreted ++ $in.compiled | select owner repo rev hash | uniq
}

export def get-latest []: table -> table {
  par-each {|l|
    nix run nixpkgs#nix-prefetch-github -- $l.owner $l.repo | from json
  }
}

def add-key []: table -> table {
  insert key {|r| $"($r.owner)/($r.repo)" }
}

export def main [] {
  let current = $configfile | get-plugins | get-current
  let latest = $current | get-latest

  let old = $current | add-key
  let new = $latest | add-key | select key rev hash | rename key new_rev new_hash

  let changes = $old | join $new key | where rev != new_rev

  let updated = $changes | reduce --fold (open --raw $configfile) {|c, text|
    $text
    | str replace $c.rev $c.new_rev
    | str replace $c.hash $c.new_hash
  }

  $updated | save --force $configfile

  $changes | select key rev new_rev
}
