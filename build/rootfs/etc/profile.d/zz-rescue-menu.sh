# cloud-rescue: open the repair menu once per interactive login (console or SSH with a
# terminal). Not for `ssh host command`, scp, or automation. RESCUE_NOMENU=1 skips it.
if [ -t 0 ] && [ -t 1 ] && [ -z "${RESCUE_NOMENU:-}" ] && [ -z "${RESCUE_MENU_SHOWN:-}" ] \
  && case $- in *i*) true ;; *) false ;; esac; then
  export RESCUE_MENU_SHOWN=1
  /usr/local/sbin/rescue-menu
fi
