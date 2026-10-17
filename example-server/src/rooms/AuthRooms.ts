import { Room, Client, AuthContext } from "@colyseus/core";
import { JWT } from "@colyseus/auth";

/**
 * Admits only a client whose matchmake request carried a valid token
 * (`Authorization: Bearer`). Joining signed out fails with AUTH_FAILED.
 */
export class AuthStaticRoom extends Room {
  static async onAuth(token: string) {
    return await JWT.verify(token);
  }
}

/**
 * Admits only a client whose WebSocket URL carried a valid token
 * (`?_authToken=`): the instance onAuth runs at connect time, after
 * matchmaking, and the HTTP header never reaches it.
 */
export class AuthInstanceRoom extends Room {
  // opts out of @colyseus/auth's matchmake-time decode, which would
  // otherwise fill client.auth and skip the instance onAuth below
  static async onAuth() {
    return true;
  }

  async onAuth(client: Client, options: any, context: AuthContext) {
    return await JWT.verify(context.token);
  }
}
