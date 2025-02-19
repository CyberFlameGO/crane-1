{ downloadCargoPackageFromGit
, lib
, runCommandLocal
, toTOML
}:

{ lockPackages
}:
let
  inherit (builtins)
    any
    attrNames
    filter
    hashString
    head
    isString
    listToAttrs
    placeholder
    split;

  inherit (lib)
    concatMapStrings
    concatStrings
    escapeShellArg
    hasPrefix
    last
    mapAttrs'
    mapAttrsToList
    nameValuePair
    removePrefix;

  # compat(2.5): fallback to lib.groupBy if the builtin version isn't available
  groupBy = builtins.groupBy or lib.groupBy;

  knownGitParams = [ "branch" "rev" "tag" ];
  parseGitUrl = lockUrl:
    let
      revSplit = split "#" (removePrefix "git+" lockUrl);
      # uniquely identifies the repo in terms of what cargo can address via
      # source replacement (e.g. the url along with any branch/tag/rev).
      id = head revSplit;
      # NB: this is distict from the `rev` query param which may show up
      # if the dependency is explicitly listed with a `rev` value.
      lockedRev = last revSplit;

      querySplit = split "\\?" (head revSplit);
      git = head querySplit;

      queryParamSplit = filter
        (qp: (isString qp) && any (p: hasPrefix p qp) knownGitParams)
        (split "&" (last querySplit));
      extractedParams = listToAttrs (map
        (qp:
          let
            kvSplit = (split "=" qp);
          in
          nameValuePair (head kvSplit) (last kvSplit)
        )
        queryParamSplit
      );
    in
    extractedParams // {
      inherit git id lockedRev;
    };

  hash = hashString "sha256";

  # Local crates will show up in the lock file with no checksum/source
  lockedPackagesFromGit = filter
    (p: hasPrefix "git" (p.source or ""))
    lockPackages;
  lockedGitGroups = groupBy (p: p.id) (map
    (p: (parseGitUrl p.source) // { package = p; })
    lockedPackagesFromGit
  );

  sources = mapAttrs'
    (id: ps:
      let
        p = head ps;
        ref =
          if p ? tag then "refs/tags/${p.tag}"
          else if p ? branch then "refs/heads/${p.branch}"
          else null;
      in
      nameValuePair (hash id) (downloadCargoPackageFromGit {
        inherit (p) git;
        inherit ref;
        rev = p.lockedRev;
      })
    )
    lockedGitGroups;

  configLocalSources = concatMapStrings
    (hashedId: ''
      [source.nix-sources-${hashedId}]
      directory = "${placeholder "out"}/${hashedId}"
    '')
    (attrNames sources);

  configReplaceGitSources = mapAttrsToList
    (hashedId: ps:
      let
        p = head ps;
        extractAttr = attr:
          if p ? ${attr} then ''
            ${attr} = "${p.${attr}}"
          '' else "";
        sourceValues = concatMapStrings extractAttr ([ "git" ] ++ knownGitParams);
      in
      ''
        [source."${p.id}"]
        replace-with = "nix-sources-${hash p.id}"
        ${sourceValues}
      ''
    )
    lockedGitGroups;
in
{
  inherit sources;
  config = configLocalSources + (concatStrings configReplaceGitSources);
}
