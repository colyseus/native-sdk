## Endpoint of the Prediction Playground dev server, which hosts the lab rooms
## the predict/input suites join. run-tests.sh exports
## COLYSEUS_PLAYGROUND_PORT when another dev server holds :5173.
static func url() -> String:
	var port := OS.get_environment("COLYSEUS_PLAYGROUND_PORT")
	return "ws://127.0.0.1:%s" % (port if port != "" else "5173")
