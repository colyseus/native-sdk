import {
    defineServer,
    defineRoom,
    monitor,
    playground,
    createRouter,
    createEndpoint,
    auth,
} from "colyseus";

/**
 * Import your Room files
 */
import { MyRoom } from "./rooms/MyRoom";
import { TestRoom } from "./rooms/TestRoom";
import { ViewTestRoom } from "./rooms/ViewTestRoom";

export const server = defineServer({
    rooms: {
        // Both my_room and test_room route to TestRoom so that SDK tests targeting
        // either name see the full players/currentTurn schema.
        my_room: defineRoom(TestRoom),
        test_room: defineRoom(TestRoom),
        view_test_room: defineRoom(ViewTestRoom),
        stub_room: defineRoom(MyRoom),
    },

    /**
     * HTTP API routes used by SDK HTTP tests.
     */
    routes: createRouter({
        test_get: createEndpoint("/test", { method: "GET" }, async (ctx) => {
            return { things: [1, 2, 3, 4, 5, 6] };
        }),
        test_post: createEndpoint("/test", { method: "POST" }, async (ctx) => {
            return { method: "POST", body: ctx.body };
        }),
        test_put: createEndpoint("/test", { method: "PUT" }, async (ctx) => {
            return { method: "PUT", body: ctx.body };
        }),
        test_delete: createEndpoint("/test", { method: "DELETE" }, async (ctx) => {
            return { method: "DELETE" };
        }),
        test_patch: createEndpoint("/test", { method: "PATCH" }, async (ctx) => {
            return { method: "PATCH", body: ctx.body };
        }),
    }),

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