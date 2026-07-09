let
  contract = builtins.fromTOML (
    builtins.readFile
      /nix/store/yi2ghpvzx7kg2clcl44pi6rxgzzr2x5h-source/config_metadata/main_config_contract.toml
  );

  fields = contract.fields;

  names = builtins.sort builtins.lessThan (builtins.attrNames fields);

  orElse = attrs: name: default:
    if builtins.hasAttr name attrs
    then builtins.getAttr name attrs
    else default;

  quote = builtins.toJSON;

  render = name:
    let
      f = builtins.getAttr name fields;

      validation = orElse f "validation" "";
      desc = orElse f "description" "";
      hm = orElse f "home_manager_option" name;

      default =
        if builtins.hasAttr "home_manager_default_is_null" f
          && f.home_manager_default_is_null
        then
          "null"
        else
          quote f.default;

      enumComment =
        if validation == "enum" || validation == "enum_string_list"
        then
          "# allowed: "
          + builtins.concatStringsSep ", "
            (map quote f.allowed_values)
        else
          "";

      rangeComment =
        if validation == "int_range" || validation == "float_range"
        then
          "# range: ${toString f.min}..${toString f.max}"
        else
          "";

      typeComment =
        "# kind: ${f.kind}"
        + (
          if validation != ""
          then " (${validation})"
          else ""
        );
    in
      ''
# ==============================================================================
# ${hm}
# JSON: ${name}
${typeComment}
${enumComment}
${rangeComment}
# default: ${default}
# ${desc}
${hm} = ${default};

'';

in
builtins.concatStringsSep "\n" (map render names)
