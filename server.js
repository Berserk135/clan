const express = require('express');
const session = require('express-session');
const bcrypt = require('bcryptjs');
const fs = require('fs');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());
app.use(express.static('public'));
app.use(session({
  secret: process.env.SESSION_SECRET || 'change-me-in-production',
  resave: false,
  saveUninitialized: false,
  cookie: { maxAge: 7 * 24 * 60 * 60 * 1000, httpOnly: true, sameSite: 'lax' }
}));

// ---------- Файлы данных ----------
const DATA_DIR = path.join(__dirname, 'data');
const USERS_FILE = path.join(DATA_DIR, 'users.json');
const DATA_FILE  = path.join(DATA_DIR, 'data.json');
if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });

const readJSON = (f, fb) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return fb; } };
const writeJSON = (f, o) => fs.writeFileSync(f, JSON.stringify(o, null, 2));

const loadUsers = () => readJSON(USERS_FILE, []);
const loadData  = () => {
  let d = readJSON(DATA_FILE, null);
  if (!d) {
    d = {
      players: [],
      squads: [
        { name: "1 Бой" }, { name: "2 Бой" }, { name: "3 Бой" },
        { name: "Ралли" }, { name: "БИО" }, { name: "Сапп" }
      ],
      treasury: { "1 Бой":0, "2 Бой":0, "3 Бой":0, "Ралли":0, "БИО":0, "Сапп":0 },
      selectedMembers: []
    };
    writeJSON(DATA_FILE, d);
  }
  return d;
};
const saveData = d => writeJSON(DATA_FILE, d);

// ---------- Константы ----------
const PAY_START_DATE = '2026-09-14';
const DAILY_AMOUNT   = 100000;
const MAX_DAYS_AHEAD = 30;

// ---------- Утилиты ----------
function addDays(dateStr, n) {
  const [y, m, d] = dateStr.split('-').map(Number);
  const dt = new Date(y, m - 1, d);
  dt.setDate(dt.getDate() + n);
  const yy = dt.getFullYear();
  const mm = String(dt.getMonth() + 1).padStart(2, '0');
  const dd = String(dt.getDate()).padStart(2, '0');
  return `${yy}-${mm}-${dd}`;
}
const todayStr = () => {
  const n = new Date();
  return `${n.getFullYear()}-${String(n.getMonth()+1).padStart(2,'0')}-${String(n.getDate()).padStart(2,'0')}`;
};

// ---------- Авторизация ----------
app.post('/api/login', (req, res) => {
  const { login, password } = req.body || {};
  const user = loadUsers().find(u => u.login === login);
  if (!user || !bcrypt.compareSync(password || '', user.passwordHash)) {
    return res.status(401).json({ error: 'Неверный логин или пароль' });
  }
  req.session.user = { login: user.login, role: user.role, squad: user.squad || null };
  res.json({ user: req.session.user });
});

app.post('/api/logout', (req, res) => req.session.destroy(() => res.json({ ok: true })));

const requireAuth = (req, res, next) => {
  if (!req.session.user) return res.status(401).json({ error: 'Требуется вход' });
  next();
};

app.get('/api/me', requireAuth, (req, res) => res.json({ user: req.session.user }));

// ---------- Данные (с фильтрацией по роли) ----------
app.get('/api/data', requireAuth, (req, res) => {
  const d = loadData();
  const user = req.session.user;

  let players = d.players;
  let treasury = d.treasury;

  if (user.role === 'commander') {
    players = players.filter(p => p.squad === user.squad);
    treasury = { [user.squad]: d.treasury[user.squad] || 0 };
  }

  res.json({
    user,
    players,
    squads: d.squads,
    treasury,
    selectedMembers: d.selectedMembers
  });
});

// ---------- Добавить игрока ----------
app.post('/api/players', requireAuth, (req, res) => {
  const user = req.session.user;
  const { name, priv, spd, role, squad } = req.body || {};
  if (!name) return res.status(400).json({ error: 'Имя обязательно' });

  const d = loadData();
  if (d.players.find(p => p.name === name)) return res.status(400).json({ error: 'Игрок уже есть' });

  let playerSquad = null;
  if (user.role === 'commander') {
    playerSquad = user.squad;              // авто-привязка к отряду командира
  } else if (user.role === 'caller') {
    playerSquad = squad || null;           // коллер выбирает любой
  } else {
    return res.status(403).json({ error: 'Нет прав' });
  }

  const player = {
    name,
    priv: parseFloat(priv) || 0,
    spd: parseFloat(spd) || 0,
    role: role || 'Боец',
    squad: playerSquad,
    paidUntil: null,
    lastPaidDate: null
  };
  d.players.push(player);
  saveData(d);
  res.json({ player });
});

// ---------- Удалить игрока ----------
app.delete('/api/players/:name', requireAuth, (req, res) => {
  const user = req.session.user;
  const d = loadData();
  const player = d.players.find(p => p.name === req.params.name);
  if (!player) return res.status(404).json({ error: 'Не найден' });
  if (user.role === 'commander' && player.squad !== user.squad) {
    return res.status(403).json({ error: 'Нет прав' });
  }
  d.players = d.players.filter(p => p.name !== player.name);
  d.selectedMembers = d.selectedMembers.filter(n => n !== player.name);
  saveData(d);
  res.json({ ok: true });
});

// ---------- Сменить отряд (только коллер) ----------
app.post('/api/players/:name/squad', requireAuth, (req, res) => {
  const user = req.session.user;
  if (user.role !== 'caller') return res.status(403).json({ error: 'Только коллер' });
  const d = loadData();
  const player = d.players.find(p => p.name === req.params.name);
  if (!player) return res.status(404).json({ error: 'Не найден' });
  player.squad = req.body.squad || null;
  saveData(d);
  res.json({ player });
});

// ---------- Переключить в общий сбор ----------
app.post('/api/players/:name/select', requireAuth, (req, res) => {
  const user = req.session.user;
  const d = loadData();
  const player = d.players.find(p => p.name === req.params.name);
  if (!player) return res.status(404).json({ error: 'Не найден' });
  if (user.role === 'commander' && player.squad !== user.squad) {
    return res.status(403).json({ error: 'Нет прав' });
  }
  const i = d.selectedMembers.indexOf(player.name);
  if (i === -1) d.selectedMembers.push(player.name);
  else d.selectedMembers.splice(i, 1);
  saveData(d);
  res.json({ selectedMembers: d.selectedMembers });
});

// ---------- Отметка оплаты ----------
app.post('/api/players/:name/pay', requireAuth, (req, res) => {
  const user = req.session.user;
  const days = parseInt(req.body && req.body.days, 10);
  if (!days || days < 1 || days > MAX_DAYS_AHEAD) {
    return res.status(400).json({ error: `Введите число от 1 до ${MAX_DAYS_AHEAD}` });
  }

  const d = loadData();
  const player = d.players.find(p => p.name === req.params.name);
  if (!player) return res.status(404).json({ error: 'Не найден' });
  if (user.role === 'commander' && player.squad !== user.squad) {
    return res.status(403).json({ error: 'Нет прав' });
  }

  const today = todayStr();
  if (today < PAY_START_DATE) return res.status(400).json({ error: 'Оплата ещё не началась' });
  if (player.lastPaidDate === today) return res.status(400).json({ error: 'Уже отмечен сегодня' });

  const dayBefore = addDays(PAY_START_DATE, -1);
  let lastDay = player.paidUntil;
  if (!lastDay || lastDay < dayBefore) lastDay = dayBefore;
  const newPaidUntil = addDays(lastDay, days);
  const amount = days * DAILY_AMOUNT;

  player.paidUntil = newPaidUntil;
  player.lastPaidDate = today;

  const squadName = player.squad || 'Без отряда';
  if (!d.treasury[squadName]) d.treasury[squadName] = 0;
  d.treasury[squadName] += amount;

  saveData(d);
  res.json({ player, treasury: d.treasury, amount, days });
});

// ---------- Полный сброс (только коллер) ----------
app.post('/api/reset', requireAuth, (req, res) => {
  if (req.session.user.role !== 'caller') return res.status(403).json({ error: 'Только коллер' });
  const d = loadData();
  d.players = [];
  d.selectedMembers = [];
  d.treasury = Object.fromEntries(d.squads.map(s => [s.name, 0]));
  saveData(d);
  res.json({ ok: true });
});

app.listen(PORT, () => console.log(`✔ Сервер запущен на http://localhost:${PORT}`));
