function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
};

export const init = async () => {
  console.log('hi ohio elixir peeps!!');
  const response = await fetch('https://launchscout.com');
  const text = await response.text();
  // console.log(text);
  return ["other", "stuff", "man"];
};

export const addTodo = (item, list) => [item, ...list];