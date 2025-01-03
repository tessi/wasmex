import getSecretWord from 'get-secret-word';
import getNumber from 'get-number';
import getList from 'get-list';
import getPoint from 'get-point';
export function revealSecretWord() {
  const secretWord = getSecretWord(7, "foo");
  const {x, y} = getPoint();
  return `${secretWord} ${getNumber()} ${getList().join()} x: ${x} y: ${y}`;
}

