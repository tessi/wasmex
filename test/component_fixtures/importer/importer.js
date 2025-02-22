import getSecretWord from "get-secret-word";
import getNumber from "get-number";
import getList from "get-list";
import getPoint from "get-point";
import getTuple from "get-tuple";
import print from "print";

export function printOrError(msg) {
  print(msg);
  if (msg === "error") {
    throw "error";
  }

  return msg;
}

export function printSecretWord() {
  const secret = getSecretWord(7, "foo");
  print(secret);
}
export function revealSecretWord() {
  const secretWord = getSecretWord(7, "foo");
  const { x, y } = getPoint();
  return `${secretWord} ${getNumber()} ${getList().join()} x: ${x} y: ${y}`;
}

export function showTuple() {
  const [x, y] = getTuple();
  return `${x} ${y}`;
}
