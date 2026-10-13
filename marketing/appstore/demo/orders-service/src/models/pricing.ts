export const sumOf = (items: { price: number; qty: number }[]) => items.reduce((s, i) => s + i.price * i.qty, 0);
