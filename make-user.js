const bcrypt = require('bcryptjs');
const fs = require('fs');
const path = require('path');

const [,, login, password, role, squad] = process.argv;
if (!login || !password || !['caller','commander'].includes(role)) {
  console.log('Использование: node make-user.js <логин> <пароль> <caller|commander> [отряд]');
  console.log('Пример:  node make-user.js cmdr1 secret123 commander "1 Бой"');
  process.exit(1);
}

const file = path.join(__dirname, 'data', 'users.json');
if (!fs.existsSync(path.dirname(file))) fs.mkdirSync(path.dirname(file), { recursive: true });

let users = [];
try { users = JSON.parse(fs.readFileSync(file, 'utf8')); } catch {}

if (users.find(u => u.login === login)) {
  console.log('Пользователь уже существует'); process.exit(1);
}

users.push({
  login,
  passwordHash: bcrypt.hashSync(password, 10),
  role,
  squad: role === 'commander' ? squad : null
});
fs.writeFileSync(file, JSON.stringify(users, null, 2));
console.log(`✔ Пользователь "${login}" создан (${role}${squad ? ', ' + squad : ''})`);
