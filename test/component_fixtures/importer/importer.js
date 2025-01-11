import getSecretWord from 'get-secret-word';
import getNumber from 'get-number';
import getList from 'get-list';
import getPoint from 'get-point';
import getTuple from 'get-tuple';

export function revealSecretWord() {
  const secretWord = getSecretWord(7, "foo");
  const {x, y} = getPoint();
  return `${secretWord} ${getNumber()} ${getList().join()} x: ${x} y: ${y}`;
}

export function showTuple() {
  const [x, y] = getTuple();
  return `${x} ${y}`;
}
