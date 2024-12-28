import getSecretWord from 'get-secret-word';
import getNumber from 'get-number';

export function revealSecretWord() {
  const secretWord = getSecretWord(7, "foo");
  return `${secretWord} ${getNumber()}`;
}
