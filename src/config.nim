import parseCfg
import strutils
import nativesockets

const CONFIG_FILE* = "/data/cecie/config.ini"
const LOG_FILE* = "/data/cecie/log.txt"

var config: Config = newConfig()
try:
  config = loadConfig(CONFIG_FILE)
except IOError:
  discard

let SAVE_DIRECTORY* = config.getSectionValue("", "saveDirectory", "/data")
let SERVER_PORT* = nativesockets.Port(parseInt(config.getSectionValue("", "port", "1234")))

# Worker config
let WORKER_ENABLED* = config.getSectionValue("", "workerEnabled", "false") == "true"
let SERVER_HOST* = config.getSectionValue("", "serverHost", "192.168.0.100")
let SERVER_HTTP_PORT* = parseInt(config.getSectionValue("", "serverPort", "5000"))
let WORKER_KEY* = config.getSectionValue("", "workerKey", "")
let POLL_INTERVAL* = parseInt(config.getSectionValue("", "pollInterval", "60"))

