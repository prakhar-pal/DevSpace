import Foundation

public enum PodPortRouting {
    public static let productionEnvironmentVariable = "DEVSPACE_PROD_POD_FORWARD_PORT"
    public static let developmentEnvironmentVariable = "DEVSPACE_DEV_POD_FORWARD_PORT"
    public static let productionPort: UInt16 = 8765
    public static let developmentPort: UInt16 = 8766

    static let resolverShell = """
    __devspace_valid_port() {
      case "$1" in ''|*[!0-9]*|??????*) return 1 ;; esac
      [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
    }
    __devspace_resolve_port() {
      __devspace_prod_port="${DEVSPACE_PROD_POD_FORWARD_PORT:-8765}"
      __devspace_dev_port="${DEVSPACE_DEV_POD_FORWARD_PORT:-8766}"
      if __devspace_valid_port "$__devspace_prod_port" &&
         curl -sS --max-time 1 -o /dev/null "http://localhost:$__devspace_prod_port/" 2>/dev/null; then
        printf '%s\\n' "$__devspace_prod_port"
        return 0
      fi
      if __devspace_valid_port "$__devspace_dev_port" &&
         curl -sS --max-time 1 -o /dev/null "http://localhost:$__devspace_dev_port/" 2>/dev/null; then
        printf '%s\\n' "$__devspace_dev_port"
        return 0
      fi
      return 1
    }
    """
}
