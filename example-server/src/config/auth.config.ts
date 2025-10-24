import { JWT, auth } from "@colyseus/auth";

const fakeDb: Array<{ email: string; password: string, options?: any }> = [];

auth.settings.onFindUserByEmail = async (email) => {
  console.log("@colyseus/auth: onFindByEmail =>", { email });
  return fakeDb.find((user) => user.email === email);
};

auth.settings.onRegisterWithEmailAndPassword = async (email, password, options) => {
  const user = { email, password, options };
  fakeDb.push(user);
  return user
}

export { auth };