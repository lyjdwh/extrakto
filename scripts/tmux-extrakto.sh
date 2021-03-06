#!/bin/bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LAST_ACTIVE_PANE=$1
source "$CURRENT_DIR/helpers.sh"
extrakto="$CURRENT_DIR/../extrakto.py"

# options
grab_area=$(get_option "@extrakto_grab_area")
extrakto_opt=$(get_option "@extrakto_default_opt")
clip_tool=$(get_option "@extrakto_clip_tool")
fzf_tool=$(get_option "@extrakto_fzf_tool")
open_tool=$(get_option "@extrakto_open_tool")
copy_key=$(get_option "@extrakto_copy_key")
insert_key=$(get_option "@extrakto_insert_key")

capture_pane_start=$(get_capture_pane_start "$grab_area")
original_grab_area=${grab_area}  # keep this so we can cycle between alternatives on fzf

if [[ "$clip_tool" == "auto" ]]; then
  case "`uname`" in
    'Linux')
      if [[ $(cat /proc/sys/kernel/osrelease) =~ 'Microsoft' ]]; then
        clip_tool='clip.exe'
      else
        clip_tool='xclip -i -selection clipboard >/dev/null'
      fi
      ;;
    'Darwin') clip_tool='pbcopy' ;;
    *) ;;
  esac
fi

if [[ "$open_tool" == "auto" ]]; then
  case "`uname`" in
    'Linux') open_tool='xdg-open >/dev/null' ;;
    'Darwin') open_tool='open' ;;
    *) open_tool='' ;;
  esac
fi

if [[ -z $EDITOR ]]; then
  # fallback
  editor="vi"
else
  editor="$EDITOR"
fi

function capture_panes() {
  if [[ $grab_area =~ ^window\  ]]; then
    for pane in $(tmux list-panes -F "#{pane_active}:#{pane_id}"); do
      if [[ $pane =~ ^0: && ${pane:2} != ${LAST_ACTIVE_PANE} ]]; then
        local captured+=$(tmux capture-pane -pJS ${capture_pane_start} -t ${pane:2})
        local captured+=$'\n'
      fi
    done
  fi
  local captured+=$(tmux capture-pane -pJS ${capture_pane_start} -t !)

  echo "$captured"
}

function capture() {

  header="${insert_key}=insert, ${copy_key}=copy"
  if [ -n "$open_tool" ]; then header="$header, ctrl-o=open"; fi
  header="$header, ctrl-e=edit"
  header="$header, ctrl-f=toggle filter [$extrakto_opt], ctrl-g=grab area [$grab_area]"

  case $extrakto_opt in
    'path/url') extrakto_flags='pu' ;;
    'lines') extrakto_flags='l' ;;
    *) extrakto_flags='w' ;;
  esac

  # for troubleshooting add
  # tee /tmp/stageN | \
  # between the commands
  sel=$(capture_panes | \
    $extrakto -r$extrakto_flags | \
    (read line && (echo $line; cat) || echo NO MATCH - use a different filter) | \
    $fzf_tool \
      --header="$header" \
      --expect=${insert_key},${copy_key},ctrl-e,ctrl-f,ctrl-g,ctrl-o,ctrl-c,esc \
      --tiebreak=index)

  res=$?
  key=$(head -1 <<< "$sel")
  text=$(tail -n +2 <<< "$sel")

  if [ $res -gt 0 -a "$key" == "" ]; then
    echo "error: unable to extract - check/report errors above"
    echo "You can also set the fzf path in options (see readme)."
    read
    exit
  fi

  case $key in

    ${copy_key})
      tmux set-buffer -- "$text"
      # run in background as xclip won't work otherwise
      tmux run-shell -b "tmux show-buffer|$clip_tool"
      ;;

    ${insert_key})
      tmux set-buffer -- "$text"
      tmux paste-buffer -t !
      ;;

    ctrl-f)
      if [[ $extrakto_opt == 'word' ]]; then
        extrakto_opt='path/url'
      elif [[ $extrakto_opt == 'path/url' ]]; then
        extrakto_opt='lines'
      else
        extrakto_opt='word'
      fi
      capture
      ;;

    ctrl-g)
      # cycle between options like this:
      # recent -> full -> window recent -> window full -> custom (if any) -> recent ...
      tmux_pane_num=$(tmux list-panes | wc -l)
      if [[ $grab_area == "recent" ]]; then
          if [[ $tmux_pane_num -eq 2 ]]; then
              grab_area="full"
          else
              grab_area="window recent"
          fi
      elif [[ $grab_area == "window recent" ]]; then
          grab_area="full"
      elif [[ $grab_area == "full" ]]; then
          if [[ $tmux_pane_num -eq 2 ]]; then
              grab_area="recent"

              if [[ ! "$original_grab_area" =~ ^(window )?(recent|full)$ ]]; then
                  grab_area="$original_grab_area"
              fi
          else
              grab_area="window full"
          fi
      elif [[ $grab_area == "window full" ]]; then
          grab_area="recent"

          if [[ ! "$original_grab_area" =~ ^(window )?(recent|full)$ ]]; then
              grab_area="$original_grab_area"
          fi
      else
          grab_area="recent"
      fi

      capture_pane_start=$(get_capture_pane_start "$grab_area")

      capture
      ;;

    ctrl-o)
      if [ -n "$open_tool" ]; then
        tmux run-shell -b "cd $PWD; $open_tool $text"
      else
        capture
      fi
      ;;

    ctrl-e)
      tmux send-keys -t ! "$editor -- $text" 'C-m'
      ;;
  esac
}

# check terminal size, zoom pane if too small
lines=$(tput lines)
if [ $lines -lt 7 ]; then
  tmux resize-pane -Z
fi

capture
