import {
    defineServer,
    defineRoom,
    monitor,
    playground,
    auth,
} from "colyseus";

/**
 * Import your Room files
 */
import { MyRoom } from "./rooms/MyRoom";
import { TestRoom } from "./rooms/TestRoom";

export const server = defineServer({
    rooms: {
        my_room: defineRoom(MyRoom),
        test_room: defineRoom(TestRoom),
    },

    express: (app) => {
        /**
         * Bind your custom express routes here:
         * Read more: https://expressjs.com/en/starter/basic-routing.html
         */
        app.get("/hello_world", (req, res) => {
            res.send("It's time to kick ass and chew bubblegum!");
        });

        /**
         * Use @colyseus/playground
         * (It is not recommended to expose this route in a production environment)
         */
        if (process.env.NODE_ENV !== "production") {
            app.use("/", playground());
        }

        /**
         * Bind auth routes
         */
        app.use(auth.prefix, auth.routes());

        /**
         * Use @colyseus/monitor
         * It is recommended to protect this route with a password
         * Read more: https://docs.colyseus.io/tools/monitor/#restrict-access-to-the-panel-using-a-password
         */
        app.use("/monitor", monitor());
    },

    beforeListen: () => {
        /**
         * Before before gameServer.listen() is called.
         */
    }
});

export default server;