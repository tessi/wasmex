import getSecretWord from 'get-secret-word';

export function revealSecretWord() {
  return getSecretWord(1, "foo");
}
