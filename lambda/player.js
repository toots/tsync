// Folder-wide audio player for browse.html: every audio file of the current
// folder becomes a playlist with a track list, prev/next and shuffle. Volume
// and seeking come from the native <audio> controls.
//
// Inlined into browse.html at serve time by both deployments (the share Lambda
// and the http-proxy frontend), so the page stays a single request.
const AudioPlayer = (() => {
  let tracks = []; // full folder listing, in display order
  let queue = []; // playback order
  let idx = 0;
  let shuffle = false;
  let resolveUrl = null; // name -> Promise<url>
  let onTrack = null; // called with the track that starts playing
  let audio = null;
  let listEl = null;
  let shuffleBtn = null;

  function shuffled(list) {
    for (let i = list.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [list[i], list[j]] = [list[j], list[i]];
    }
    return list;
  }

  // Playback order, always keeping `current` as the playing track.
  function buildQueue(current) {
    queue = shuffle
      ? [current, ...shuffled(tracks.filter((t) => t !== current))]
      : tracks.slice();
    idx = queue.indexOf(current);
  }

  function renderList() {
    listEl.innerHTML = "";
    queue.forEach((t, i) => {
      const li = document.createElement("li");
      li.textContent = t.name;
      if (i === idx) li.className = "on";
      li.onclick = () => play(i);
      listEl.appendChild(li);
    });
  }

  async function play(i) {
    idx = i;
    const t = queue[idx];
    renderList();
    onTrack(t);
    audio.src = await resolveUrl(t.name);
    audio.play().catch(() => {}); // autoplay blocked: controls still work
  }

  const step = (d) => {
    const i = idx + d;
    if (i >= 0 && i < queue.length) play(i);
  };

  function setShuffle(on) {
    shuffle = on;
    shuffleBtn.setAttribute("aria-pressed", String(on));
    shuffleBtn.textContent = on ? "🔀 Shuffle" : "🔁 In order";
    buildQueue(queue[idx]);
    renderList();
  }

  function build(container) {
    container.innerHTML = "";
    audio = Object.assign(document.createElement("audio"), { controls: true });
    audio.onended = () => step(1);

    const bar = document.createElement("div");
    bar.className = "ap-bar";
    const btn = (label, fn) => {
      const b = document.createElement("button");
      b.className = "btn";
      b.textContent = label;
      b.onclick = fn;
      return b;
    };
    shuffleBtn = btn("", () => setShuffle(!shuffle));
    bar.append(
      btn("⏮", () => step(-1)),
      btn("⏭", () => step(1)),
      shuffleBtn,
    );

    listEl = document.createElement("ul");
    listEl.className = "ap-list";
    container.append(audio, bar, listEl);
  }

  return {
    // opts: { container, tracks, start, resolveUrl, onTrack }
    open(opts) {
      tracks = opts.tracks;
      resolveUrl = opts.resolveUrl;
      onTrack = opts.onTrack;
      build(opts.container);
      shuffleBtn.setAttribute("aria-pressed", String(shuffle));
      shuffleBtn.textContent = shuffle ? "🔀 Shuffle" : "🔁 In order";
      buildQueue(opts.start);
      return play(idx);
    },
    stop() {
      if (audio) audio.pause();
    },
  };
})();
