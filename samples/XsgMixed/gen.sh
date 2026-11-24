#!/usr/bin/env bash
# gen.sh: generates Lib (XSG|BAML) and App (XSG|BAML) projects from the templates under tpl/.
set -euo pipefail
cd "$(dirname "$0")"
lib() { # lib <Name> <P> <Other> <Q> <xsg:true|false>
  d="$1"; rm -rf "$d"; mkdir -p "$d/Themes" "$d/Sub"
  for f in tpl/lib/*.xaml tpl/lib/*.cs; do
    b="$(basename "$f")"; o="$d/$(echo "$b" | sed "s/^P/$2/")"
    sed -e "s/@NS@/$1/g" -e "s/@P@/$2/g" -e "s/@OTHER@/$3/g" -e "s/@Q@/$4/g" "$f" > "$o"
  done
  mv "$d/Generic.xaml" "$d/Themes/Generic.xaml"; mv "$d/$2Sub.xaml" "$d/Sub/$2Sub.xaml"
  { cat tpl/lib.csproj.head; if [ "$5" = true ]; then cat tpl/xsg.props; fi; echo '  <ItemGroup>'
    for x in "$d"/*.xaml "$d"/Themes/Generic.xaml "$d"/Sub/*.xaml; do r="${x#$d/}"; if [ "$5" = true ]; then echo "    <AdditionalFiles Include=\"$r\" />"; fi; done
    echo '  </ItemGroup>'; if [ "$5" = true ]; then echo '  <Import Project="../tpl/XsgLocal.targets" />'; fi; echo '</Project>'; } > "$d/$1.csproj"
}
lib LibX X LibB B true
lib LibB B LibX X false
for mode in Xsg Baml; do
  d="App$mode"; rm -rf "$d"; mkdir -p "$d"
  for f in tpl/app/*.xaml tpl/app/*.cs; do sed -e "s/@MODE@/$mode/g" "$f" > "$d/$(basename "$f")"; done
  for kind in Dict Class Ctl Rich; do for pl in "X LibX" "B LibB"; do set -- $pl; for e in xaml xaml.cs; do sed -e "s/@MODE@/$mode/g" -e "s/@P@/$1/g" -e "s/@KIND@/$kind/g" -e "s/@LIB@/$2/g" tpl/app/Win$kind.$e.tpl > "$d/Win$kind$1.$e"; done; done; done
  xsg=false; [ "$mode" = Xsg ] && xsg=true
  { sed "s/@MODE@/$mode/g" tpl/app.csproj.head
    if [ "$xsg" = true ]; then cat tpl/xsg.props; echo '  <ItemGroup>'
      for w in "$d"/*.xaml; do echo "    <AdditionalFiles Include=\"$(basename "$w")\" />"; done
      echo '  </ItemGroup>'; echo '  <Import Project="../tpl/XsgLocal.targets" />'; fi
    echo '</Project>'; } > "$d/App$mode.csproj"
done
