import { Router } from "express";
import { db } from "../models/db";
import { notify } from "../jobs/notify";
import { sumOf } from "../models/pricing";

export const orders = Router();

// Create an order and tell the customer
orders.post("/", async (req, res) => {
  const { items, userId } = req.body;
  const total = sumOf(items);

  const order = await db.orders.insert({ userId, total });
  await notify(userId, `Order #${order.id} confirmed`);
  res.status(201).json(order);
});

orders.get("/:id", async (req, res) => {
  const order = await db.orders.find(req.params.id);
  if (!order) return res.sendStatus(404);
  res.json(order);
});

orders.delete("/:id", async (req, res) => {
  await db.orders.remove(req.params.id);
  res.sendStatus(204);
});
