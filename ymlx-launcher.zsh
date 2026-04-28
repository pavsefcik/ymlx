# ymlx — your MLX model manager
# Add this line to ~/.zshrc:
#   source "/path/to/ymlx-launcher.zsh"
# Then reload your shell:  source ~/.zshrc

_YMLX_DIR="${0:A:h}"
ymlx() { zsh "$_YMLX_DIR/ymlx.zsh" "$@"; }
